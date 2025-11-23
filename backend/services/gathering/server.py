from typing import Optional
from pathlib import Path
from dotenv import load_dotenv
import os
from pydantic import BaseModel
from fastapi import APIRouter, HTTPException
from backend.utils import session
from backend.db import database as db


# ==============================
#         Load Variables
# ==============================
env_path = Path(__file__).resolve().parents[2] / "utils" / ".env" # go back 2 levels of directories (to /backend) and then go to /utils/.env
load_dotenv(env_path)

REGISTER_INTERESTS_LABELS: list = list(os.getenv("REGISTER_INTERESTS_LABELS", []))


# ==============================
#        Payload Classes
# ==============================
class User(BaseModel):
    username: Optional[str] = None
    token: str

class Interests(User):
    interests: list[str]

class Questions(User):
    answers: list[int] # range=[0,4]



# ===============================
#        Fast API Router
# ===============================
router = APIRouter(prefix="/services/gathering", tags=["challenges"])




# ==============================================
# ================== ROUTES ====================
# ==============================================

# ==========================
#         interests
# ==========================
@router.post("/interests", status_code = 200)
def set_interests(payload: Interests):
    ok, user_id = session.verify_session(payload.token)
    interests = payload.interests

    # 1. Check session and insterests validity
    if not ok:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    if not interests or not all(interest in REGISTER_INTERESTS_LABELS for interest in interests):
        raise HTTPException(status_code = 400, detail = f"Invalid interests format, check allowed interests labels: {REGISTER_INTERESTS_LABELS}")
    
    # 2. Update the user
    result = db.update_one(
        table_name="users",
        keys_dict={"user_id": user_id},
        values_dict={"$set": {"interests_info": interests}}
    )
    if result.matched_count == 0:
        raise HTTPException(status_code = 402, detail = "User not found")
    
    return {"status": True}


# ==========================
#         questions
# ==========================
@router.post("/questions", status_code = 200)
def set_questions(payload: Questions):
    ok, user_id = session.verify_session(payload.token)
    answers = payload.answers

    # 1. Check session and insterests validity
    if not ok:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    if not answers or not all(0 <= answer <= 4 for answer in answers):
        raise HTTPException(status_code = 400, detail = "Invalid answers format")
    
    # 2. Update the user
    result = db.update_one(
        table_name="users",
        keys_dict={"user_id": user_id},
        values_dict={"$set": {"questions_info": answers}}
    )
    if result.matched_count == 0:
        raise HTTPException(status_code = 402, detail = "User not found")
    
    return {"status": True}