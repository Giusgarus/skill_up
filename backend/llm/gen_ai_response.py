import os
import json
import logging
import re
import requests

from collections import defaultdict
from datetime import datetime, timedelta
from threading import Lock
from typing import List, Optional, Dict, Any
from fastapi import FastAPI, Request, HTTPException, Header

import google.generativeai as genai
from google.generativeai.types import HarmCategory, HarmBlockThreshold
from dotenv import load_dotenv
from fastapi import FastAPI, Query, Request, HTTPException, status, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel, Field, validator

from utils import *
# -----------------------
# Logging (file + console)
# -----------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    handlers=[
        logging.FileHandler("app.log"),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

# -----------------------
# Environment & Gemini
# -----------------------
load_dotenv()
api_key = os.getenv("GOOGLE_API_KEY")
if not api_key:
    logger.error("GOOGLE_API_KEY environment variable not set.")
    raise RuntimeError("Missing required environment variable: GOOGLE_API_KEY")

genai.configure(api_key=api_key)

SAFETY_SETTINGS = {
    HarmCategory.HARM_CATEGORY_HARASSMENT: HarmBlockThreshold.BLOCK_MEDIUM_AND_ABOVE,
    HarmCategory.HARM_CATEGORY_HATE_SPEECH: HarmBlockThreshold.BLOCK_MEDIUM_AND_ABOVE,
    HarmCategory.HARM_CATEGORY_SEXUALLY_EXPLICIT: HarmBlockThreshold.BLOCK_MEDIUM_AND_ABOVE,
    HarmCategory.HARM_CATEGORY_DANGEROUS_CONTENT: HarmBlockThreshold.BLOCK_MEDIUM_AND_ABOVE,
}

model = genai.GenerativeModel(
    "gemini-2.5-flash",
    safety_settings=SAFETY_SETTINGS
)

# -----------------------
# App + CORS + Templates
# -----------------------
app = FastAPI()
templates = Jinja2Templates(directory="templates")  # put index.html in templates/


raw_allowed = os.getenv(
    "ALLOWED_ORIGINS", "http://localhost:*,http://127.0.0.1:*"
).split(",")

# Trim whitespace and drop empty entries
raw_allowed = [s.strip() for s in raw_allowed if s and s.strip()]

# If user explicitly set wildcard '*' -> allow all origins (dev only)
if "*" in raw_allowed:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
        max_age=3600,
    )
else:
    # Separate exact origins and wildcard patterns
    exact_origins = [o for o in raw_allowed if "*" not in o]
    wildcard_origins = [o for o in raw_allowed if "*" in o]

    if wildcard_origins:
        # Convert wildcard patterns like http://localhost:* to a regex
        # Escape dots, replace '*' with '.*'
        regex_parts = []
        for p in wildcard_origins:
            escaped = re.escape(p).replace(r"\*", ".*")
            regex_parts.append(escaped)
        allow_origin_regex = r"^(" + "|".join(regex_parts) + r")$"

        app.add_middleware(
            CORSMiddleware,
            allow_origins=exact_origins,           # may be empty list
            allow_origin_regex=allow_origin_regex,
            allow_credentials=True,
            allow_methods=["*"],
            allow_headers=["*"],
            max_age=3600,
        )
    else:
        # No wildcards: use exact list
        app.add_middleware(
            CORSMiddleware,
            allow_origins=exact_origins,
            allow_credentials=True,
            allow_methods=["*"],
            allow_headers=["*"],
            max_age=3600,
        )


# -----------------------
# Security headers middleware
# -----------------------
@app.middleware("http")
async def add_security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["X-XSS-Protection"] = "1; mode=block"
    response.headers["Content-Security-Policy"] = "default-src 'self'"
    return response

# -----------------------
# Rate limiting (thread-safe)
# -----------------------
request_counts: Dict[str, List[datetime]] = defaultdict(list)
rate_lock = Lock()
RATE_LIMIT = int(os.getenv("RATE_LIMIT", "10"))  # requests
RATE_WINDOW = int(os.getenv("RATE_WINDOW", "60"))  # seconds

def check_rate_limit(ip_address: str) -> bool:
    now = datetime.now()
    cutoff = now - timedelta(seconds=RATE_WINDOW)
    with rate_lock:
        # Clean old requests
        request_counts[ip_address] = [
            t for t in request_counts[ip_address] if t > cutoff
        ]
        if len(request_counts[ip_address]) >= RATE_LIMIT:
            return False
        request_counts[ip_address].append(now)
        return True


# -----------------------
# Input/Output models
# -----------------------
class UserInfo(BaseModel):
    title: Optional[str] = Field("", max_length=100)
    completed: Optional[bool] = False

class GenerateRequest(BaseModel):
    goal: str = Field(description= "The goal or the plan the user wants to create in order to improve a skill or a habit", max_length=500)
    level: str = Field("beginner", description= "The level of each task the user is provided", max_length=50) 
    history: List[UserInfo] = []
    
    @validator("goal")
    def goal_min_length(cls, v):
        if len(v.strip()) < 3:
            raise ValueError("Goal must be at least 3 characters long")
        return v.strip()

    @validator("level", pre=True, always=True)
    def level_default_and_lower(cls, v):
        if not v:
            return "beginner"
        return str(v).lower()


class ReplanTask(BaseModel):
    goal: str = Field(description= "The goal or the plan the user wants to create in order to improve a skill or a habit", max_length=100)
    level: str = Field("beginner", description= "The level of each task the user is provided", max_length=50) 
    previous_task: str = Field(description="The title and description of the task the user wants to change", max_length=500)
    llm_response: str = Field(description="The original LLM response in JSON format containing the list of the tasks", max_length=2500)
    modification_reason: Optional[str] = Field("", description="The reason why the user wants to change the task", max_length=100)

# -----------------------
# Helpers
# -----------------------
def get_client_ip(request: Request) -> str:
    forwarded = request.headers.get("X-Forwarded-For")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else "unknown"

# -----------------------
# Routes
# -----------------------
@app.get("/")
async def index(request: Request):
    # serve an index.html from templates/ if present
    return templates.TemplateResponse("index.html", {"request": request})

@app.get("/health")
async def health():
    return {"status": "healthy"}

@app.post("/generate-challenge")
async def handle_challenge_request(req: Request, payload: GenerateRequest):
    client_ip = get_client_ip(req)
    if not check_rate_limit(client_ip):
        logger.warning("Rate limit exceeded for IP: %s", client_ip)
        raise HTTPException(status_code=429, detail="Too many requests. Please try again later.")

    logger.info("Received request from IP: %s", client_ip)
    try:
        # Call core generator
        challenge_data, challenge_meta = generate_challenge(payload.goal, payload.level, [item.dict() for item in payload.history or []])
        logger.info("Successfully generated challenge: %s", challenge_data.get("challenge_title", "N/A"))
        return JSONResponse(
            content={
                "challenge_data": challenge_data,
                "challenge_meta": challenge_meta,
            },
            status_code=200
        )
    except ValueError as e:
        logger.warning("Validation error: %s", str(e))
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        logger.error("Unexpected error in handle_challenge_request: %s", str(e), exc_info=True)
        raise HTTPException(status_code=500, detail="Failed to generate challenge. Please try again.")
    
    
@app.post("/replan-task")
async def handle_replan_request(req: Request, payload: ReplanTask):
    # client_ip = get_client_ip(req)
    # if not check_rate_limit(client_ip):
    #     logger.warning("Rate limit exceeded for IP: %s", client_ip)
    #     raise HTTPException(status_code=429, detail="Too many requests. Please try again later.")
    try:
        body = await req.json()
    except Exception as e:
        raise HTTPException(status_code=400, detail="Invalid JSON body")
    import pprint; pprint.pprint(body)
    # logger.info("Received request from IP: %s", client_ip)
    try:
        # Call core generator
        new_task = replan_task(payload.goal, payload.level, payload.previous_task, payload.llm_response, payload.modification_reason)
        logger.info("Successfully replaned task: %s", new_task.get("challenge_title", "N/A"))
        return JSONResponse(content=new_task, status_code=200)
    except ValueError as e:
        logger.warning("Validation error: %s", str(e))
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        logger.error("Unexpected error in handle_challenge_request: %s", str(e), exc_info=True)
        raise HTTPException(status_code=500, detail="Failed to generate challenge. Please try again.")
# @app.post("/replan-task")
# async def debug_replan(req: Request, authorization: str = Header(None)):
#     try:
#         body = await req.json()
#     except Exception as e:
#         raise HTTPException(status_code=400, detail="Invalid JSON body")

#     # Log body to console for debugging
#     import pprint; pprint.pprint(body)
#     return JSONResponse({"ok": True, "received": body})


# -----------------------
# Custom exception handlers
# -----------------------
@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException):
    # Keep logging and consistent JSON structure
    logger.warning("HTTPException: %s - %s", exc.status_code, exc.detail)
    return JSONResponse({
        "error": exc.status_code,
        "message": exc.detail
    }, status_code=exc.status_code)

@app.exception_handler(Exception)
async def general_exception_handler(request: Request, exc: Exception):
    logger.error("Unhandled exception: %s", str(exc), exc_info=True)
    return JSONResponse({
        "error": "Internal Server Error",
        "message": "An unexpected error occurred. Please try again later."
    }, status_code=500)

# -----------------------
# Run (uvicorn) - only when executed directly
# -----------------------
if __name__ == "__main__":
    import uvicorn
    port = int(os.getenv("PORT", 8001))
    debug_mode = os.getenv("ENV", "production") != "production"
    logger.info("Starting FastAPI server on port %d, debug=%s", port, debug_mode)
    uvicorn.run("app:app", host="0.0.0.0", port=port, reload=debug_mode)
    
    
    
    
    
    
    
    
    
    
    
    
    
#     {
#   "goal": "I want to bulk up",
#   "level": "beginner",
#   "previous_task": {
#       "task_id": 3,
#       "plan_id": 1,
#       "user_id": "9cd9970e-23f2-4dec-a4e4-8fbee5dd9b71",
#       "title": "Push-Up Primer",
#       "description": "Perform 3 sets of push-ups to failure (on knees or toes). Record your reps for each set and aim to improve next time.",
#       "difficulty": 1,
#       "score": 10,
#       "deadline_date": "2025-12-01",
#       "completed_at": null,
#       "deleted": false
#   },
#   "llm_response": {
#           "challenges_list": [
#       {
#         "challenge_title": "Protein Power-Up",
#         "challenge_description": "Log your protein intake for one day. Aim for 0.7-1 gram per pound of body weight. Identify 3 new high-protein foods.",
#         "duration_minutes": 15,
#         "difficulty": "Easy",
#         "day_offset": 0
#       },
#       {
#         "challenge_title": "Squat Scroll",
#         "challenge_description": "Watch a 5-minute video on proper bodyweight squat form. Practice 10 perfect bodyweight squats, focusing on depth and posture.",
#         "duration_minutes": 10,
#         "difficulty": "Easy",
#         "day_offset": 1
#       },
#       {
#         "challenge_title": "Meal Prep Map",
#         "challenge_description": "Plan 3 protein-rich meals for the upcoming week. List ingredients needed for each, ensuring they fit your bulking goals.",
#         "duration_minutes": 20,
#         "difficulty": "Medium",
#         "day_offset": 2
#       },
#       {
#         "challenge_title": "Push-Up Primer",
#         "challenge_description": "Perform 3 sets of push-ups to failure (on knees or toes). Record your reps for each set and aim to improve next time.",
#         "duration_minutes": 10,
#         "difficulty": "Easy",
#         "day_offset": 3
#       }
#     ]
    
#   },
#   "modification_reason": "Push-ups are really hard for me."
# }