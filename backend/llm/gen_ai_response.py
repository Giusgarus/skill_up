import os
import json
import logging
import re
import requests

from collections import defaultdict
from datetime import datetime, timedelta
from threading import Lock
from typing import List, Optional, Dict, Any

import google.generativeai as genai
from google.generativeai.types import HarmCategory, HarmBlockThreshold
from dotenv import load_dotenv
from fastapi import FastAPI, Query, Request, HTTPException, status, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel, Field, validator

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

# -----------------------
# Validation & Sanitization
# -----------------------
def validate_and_sanitize_input(goal: str, level: str, history: List[Dict[str, Any]]):
    # 1. length + trivial checks handled by pydantic, but keep extra checks
    
    #################### WE SHOULD CHECK IF THIS LENGTH (500) IS RESTRICTIVE ENOUGH ##############
    if len(goal) > 500:
        return None, None, None, "Goal exceeds maximum length of 500 characters"

    goal_lower = goal.lower()

    # 2. prompt injection patterns
    injection_patterns = [
        r"ignore\s+(previous|above|all)\s+instructions?",
        r"disregard\s+(previous|above|all)",
        r"forget\s+(everything|previous|above)",
        r"new\s+instructions?:",
        r"system\s*:",
        r"assistant\s*:",
        r"override\s+",
        r"act\s+as\s+",
        r"pretend\s+(you are|to be)",
        r"you\s+are\s+now",
        r"jailbreak",
        r"<\s*script",
        r"</?\s*prompt\s*>",
        r"{{.*}}",
    ]

    for pattern in injection_patterns:
        if re.search(pattern, goal_lower, re.IGNORECASE):
            logger.warning("Potential prompt injection detected: %s", pattern)
            return None, None, None, "Invalid input detected. Please rephrase your goal."

    # 3. malicious keywords
    malicious_keywords = [
        "hack", "exploit", "illegal", "drugs", "weapons",
        "violence", "harm", "suicide", "self-harm", "prompt"
    ]
    suspicious_word_count = sum(1 for w in malicious_keywords if w in goal_lower)
    if suspicious_word_count >= 2:
        logger.warning("Suspicious content detected in goal")
        return None, None, None, "Goal contains inappropriate content"

    # 4. remove dangerous characters
    sanitized_goal = re.sub(r'[^\w\s.,!?\-\'"()]', "", goal).strip()

    # 5. level
    valid_levels = ["beginner", "intermediate", "advanced"]
    sanitized_level = level.lower()
    if sanitized_level not in valid_levels:
        sanitized_level = "beginner"

    # 6. history sanitization
    if not isinstance(history, list):
        history = []
    # If we have history we keep the last 20 requests by the user. I think we won't have that many!!!
    if len(history) > 3:
        history = history[-1:]

    sanitized_history = []
    for item in history:
        if isinstance(item, dict):
            safe_item = {
                "title": str(item.get("title", ""))[:100],
                "completed": bool(item.get("completed", False))
            }
            sanitized_history.append(safe_item)
    
    # client = language.LanguageServiceClient()
    # document = language.Document(
    #     content=goal,
    #     type_=language.Document.Type.PLAIN_TEXT,
    # )
    # goal_toxicity_review = client.moderate_text(document=document)
    # print(goal_toxicity_review)
    
    return sanitized_goal, sanitized_level, sanitized_history, None

def validate_ai_response(response_data: dict):
    # CORRECTED KEYS (Fixed spelling: 'challenges')
    required_keys = ["challenges_list", "challenges_count"]
    required_secondary_keys = ["challenge_title", "challenge_description", "difficulty"]
    
    length = 0
    full_answer_txt = ""

    # 1. Validate Top Level Structure
    if not all(k in response_data for k in required_keys):
        return False, "Invalid response structure: Missing top-level keys"
    
    if not isinstance(response_data["challenges_list"], list):
        return False, "Invalid format: challenges_list must be a list"
    
    if not isinstance(response_data["challenges_count"], int):
        return False, "Invalid format: challenges_count must be an integer"

    # 2. Validate Each Challenge inside the list
    for challenge in response_data["challenges_list"]:
        # Check secondary keys existence
        if not all(k in challenge for k in required_secondary_keys):
            return False, "Invalid response structure: Missing secondary keys"

        # Validate Data Types
        if not isinstance(challenge["challenge_title"], str):
            return False, "Invalid title format"
        if not isinstance(challenge["challenge_description"], str):
            return False, "Invalid description format"
        if not isinstance(challenge["difficulty"], str):
            return False, "Invalid difficulty format"

        # Validate Values / Constraints
    
        # Difficulty fallback
        if challenge["difficulty"] not in ["Easy", "Medium", "Hard"]:
            challenge["difficulty"] = "Easy"

        # Length Truncation (CRITICAL FIX: referencing 'challenge', not 'response_data')
        if len(challenge["challenge_title"]) > 100:
            challenge["challenge_title"] = challenge["challenge_title"][:100]
        if len(challenge["challenge_description"]) > 200:
            challenge["challenge_description"] = challenge["challenge_description"][:500]

        # Accumulate text for safety check
        length += len(challenge["challenge_title"]) + len(challenge["challenge_description"])
        full_answer_txt += " " + (challenge["challenge_title"] + " " + challenge["challenge_description"]).lower()

    if length > 2000: # Increased slightly to allow for multiple challenges
        return False, "Response too lengthy"

    # 3. Safety / XSS Check
    dangerous_patterns = [r"<script", r"javascript:", r"onerror=", r"onclick=", r"eval\(", r"<iframe", r"prompt"]
    for pattern in dangerous_patterns:
        if re.search(pattern, full_answer_txt, re.IGNORECASE):
            return False, "Response contains potentially harmful content"

    return True, None

# -----------------------
# Core AI Function
# -----------------------
def generate_challenge(goal: str, level: str, history: List[Dict[str, Any]]):
    sanitized_goal, sanitized_level, sanitized_history, error = validate_and_sanitize_input(goal, level, history)
    if error:
        raise ValueError(error)

    system_instruction = """You are 'SkillUp Coach,' an expert AI gamification engine designed to turn personal habits and corporate skills into an RPG-style adventure.

    YOUR MISSION:
    Create engaging, bite-sized mini-challenges based on the user's goal. Your tone must be motivating, clear, and energetic (like a game quest giver).

    CRITICAL INSTRUCTIONS:
    1. JSON ONLY: Your output must be a strictly valid JSON object. Do not add markdown formatting (like ```json).
    2. SAFETY FIRST: Never generate challenges that are dangerous, illegal, physically harmful, or violate corporate safety policies.
    3. GAMIFY: Use action-oriented language (e.g., "Mission," "Quest," "Sprint," "Unlock").
    4. DURATION: Challenges must be doable in 5 to 30 minutes.

    OUTPUT STRUCTURE:
    You must return a JSON object containing a list of challenges.
    {
        "challenges_count": 2,
        "challenges_list": [
            {
                "challenge_title": "Quest Name (Max 60 chars)",
                "challenge_description": "Specific instructions on what to do. 1-2 sentences.",
                "difficulty": "Easy" 
            }
        ]
    }
    Difficulty levels allowed: "Easy", "Medium", "Hard".
    """
    
    user_prompt = f"""
    **PLAYER PROFILE:**
    - **Goal:** "{sanitized_goal}"
    - **Current Level:** {sanitized_level}
    - **History:** {json.dumps(sanitized_history) if sanitized_history else "New Player"}

    **MISSION REQUEST:**
    Generate a number of mini-challenge(s) corresponding to the days the user is free in during the week for this goal, if not provided generate for one week. 

    **GUIDELINES:**
    1. **Relevance:** The challenge must directly help achieve the goal.
    2. **Progression:** If the user has a history, make this challenge slightly different or harder than the last one.
    3. **Format:**
    - Title: Short, punchy, and gamified.
    - Description: 1 or 2 bullet points explaining exactly what to do.
    - Duration: Between 5 and 15 minutes.
    - Difficulty: Based on the user's level ({sanitized_level}).

    **REQUIRED JSON RESPONSE:**
    {{
    "challenges_count": <integer>,
    "challenges_list": [
        {{
        "challenge_title": "<string>",
        "challenge_description": "<string>",
        "duration_minutes": <int>,
        "difficulty": "<Easy/Medium/Hard>"
        }}
    ]
    }}
    """

    try:
        logger.info("Generating challenge for sanitized goal: %s...", sanitized_goal[:50])

        response = model.generate_content(
            [system_instruction, user_prompt],
            generation_config={
                "temperature": 0.7,
                "top_p": 0.95,
                "max_output_tokens": 2524,
                "response_mime_type": "application/json",
            }
        )

        # Safety filter check / empty response
        if not response or not hasattr(response, "text") or not response.text:
            if hasattr(response, "prompt_feedback"):
                logger.warning("Response blocked by safety filters: %s", response.prompt_feedback)
                raise ValueError("Request blocked by safety filters. Please rephrase your goal.")
            raise ValueError("Empty response from AI model")

        logger.info("Raw API response: %s...", (response.text[:400] if response.text else "None"))
        json_text = response.text.strip()

        # strip triple-backtick codeblocks if present
        if json_text.startswith("```"):
            parts = json_text.split("```")
            if len(parts) >= 2:
                json_text = parts[1]
                if json_text.startswith("json"):
                    json_text = json_text[4:]
                json_text = json_text.strip()

        challenge_data = json.loads(json_text)

        is_valid, validation_error = validate_ai_response(challenge_data)
        if not is_valid:
            logger.error("AI response validation failed: %s", validation_error)
            raise ValueError(f"Invalid AI response: {validation_error}")

        logger.info("Challenge generated and validated successfully")
        return challenge_data

    except json.JSONDecodeError as e:
        logger.error("JSON parsing error: %s", e)
        logger.error("Response text: %s", response.text if response else "None")
        raise ValueError("Failed to parse AI response")
    except Exception as e:
        logger.error("Error generating challenge: %s", str(e), exc_info=True)
        raise

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
        challenge_data = generate_challenge(payload.goal, payload.level, [item.dict() for item in payload.history or []])
        logger.info("Successfully generated challenge: %s", challenge_data.get("challenge_title", "N/A"))
        return JSONResponse(content=challenge_data, status_code=200)
    except ValueError as e:
        logger.warning("Validation error: %s", str(e))
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        logger.error("Unexpected error in handle_challenge_request: %s", str(e), exc_info=True)
        raise HTTPException(status_code=500, detail="Failed to generate challenge. Please try again.")
    

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