from typing import Annotated, Optional, Set
from pathlib import Path
import json
import os
from pydantic import BaseModel, StringConstraints
from fastapi import APIRouter, HTTPException
from pymongo.errors import PyMongoError
from backend.utils import session
from backend.db import database as db


# ==============================
#         Load Variables
# ==============================
CONFIG_PATH = Path(__file__).resolve().parents[2] / "utils" / "env.json"
with CONFIG_PATH.open("r", encoding="utf-8") as f:
    _cfg = json.load(f)

GATHERING_MIN_LEN_ADF =  _cfg.get("GATHERING_MIN_LEN_ADF")
GATHERING_MAX_LEN_ADF = _cfg.get("GATHERING_MAX_LEN_ADF")
GATHERING_INTERESTS_LABELS = _cfg.get("GATHERING_INTERESTS_LABELS")
GATHERING_ALLOWED_DATA_FIELDS = _cfg.get("GATHERING_ALLOWED_DATA_FIELDS")


# ==============================
#        Payload Classes
# ==============================
RecordStr = Annotated[
    str,
    StringConstraints(
        strip_whitespace = True,
        min_length = GATHERING_MIN_LEN_ADF,
        max_length = GATHERING_MAX_LEN_ADF,
        pattern = r"^[\x20-\x7E]+$",
    )
]

class User(BaseModel):
    token: str

class UserBody(User):
    attribute: str
    record: RecordStr

class Interests(User):
    interests: list[str]

class Questions(User):
    answers: list[int] # range=[0,4]



# ===============================
#        Fast API Router
# ===============================
router = APIRouter(prefix="/services/gathering", tags=["gathering"])



# ==============================================
# ================== ROUTES ====================
# ==============================================

# ==========================
#            get
# ==========================
@router.post("/get", status_code = 200)
def get_user(payload: UserBody) -> dict:
    ok, user_id = session.verify_session(payload.token)
    attribute = payload.attribute
    if not ok:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    user = db.find_one(
        table_name="users",
        filters = {"user_id": user_id},
        projection = {"_id": False, attribute: True}
    )
    if not user:
        raise HTTPException(status_code = 402, detail = "User not found")
    return {"status": True, attribute: user.get(attribute, None)}

# ==========================
#            set
# ==========================
@router.post("/set", status_code = 200)
def update_user(payload: UserBody):
    valid_token, user_id = session.verify_session(payload.token)
    if not valid_token:
        raise HTTPException(status_code = 400, detail = "Invalid or missing token")
    attribute = payload.attribute.strip()
    if attribute not in GATHERING_ALLOWED_DATA_FIELDS:
        raise HTTPException(status_code = 401, detail = "Unsupported attribute")
    # Special-case username to avoid collisions
    if attribute == "username":
        existing = db.find_one(
            table_name="users",
            filters={"username": payload.record},
            projection={"_id": False, "user_id": True},
        )
        if existing and existing.get("user_id") != user_id:
            raise HTTPException(status_code=409, detail="Username already in use")
    try:
        up_status = db.update_one(
            table_name="users",
            keys_dict={"user_id" : user_id},
            values_dict={"$set": {payload.attribute: payload.record}}
        )
    except PyMongoError:
        raise HTTPException(status_code = 402, detail = "Database error")
    if up_status.matched_count == 0:
            raise HTTPException(status_code = 403, detail = "User not found")
    return {"status": True, "attribute": attribute, "new_record": payload.record}

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
    label_index = {label.lower(): idx for idx, label in enumerate(GATHERING_INTERESTS_LABELS)}
    try:
        interests_idx = [label_index[i.lower()] for i in interests]
    except Exception:
        raise HTTPException(status_code = 400, detail = f"Invalid interests format, check allowed interests labels: {GATHERING_INTERESTS_LABELS}")
    
    # 2. Update the user
    result = db.update_one(
        table_name="users",
        keys_dict={"user_id": user_id},
        values_dict={"$set": {"interests_info": interests_idx}}
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
