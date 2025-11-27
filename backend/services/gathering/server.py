from typing import Annotated, Optional, Set
from pathlib import Path
import json
import os
from pydantic import BaseModel, ConfigDict, Field, StringConstraints
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
    token: str = Field(..., description="User session token (Bearer).")

class UserAttribute(User):
    attribute: str = Field(..., description="Name of the attribute to read.")

class UserBody(User):
    attribute: str = Field(..., description="Name of the attribute to update.")
    record: Annotated[RecordStr, Field(description="New value to apply to the given attribute.")]

class Interests(User):
    interests: list[str] = Field(..., description="List of interests (allowed labels only).")

class Questions(User):
    answers: list[int] = Field(..., description="Numeric answers between 0 and 4 (inclusive).")


class StatusResponse(BaseModel):
    status: bool = Field(..., description="Operation outcome flag.")


class UserDataResponse(StatusResponse):
    model_config = ConfigDict(extra="allow")


class UpdateUserResponse(StatusResponse):
    attribute: str = Field(..., description="Updated attribute name.")
    new_record: RecordStr = Field(..., description="Value applied to the attribute.")


class ErrorResponse(BaseModel):
    detail: str = Field(..., description="Error detail.")



# ===============================
#        Fast API Router
# ===============================
router = APIRouter(prefix="/services/gathering", tags=["User Data"])



# ==============================================
# ================== ROUTES ====================
# ==============================================

# ==========================
#            get
# ==========================
@router.post(
    "/get",
    status_code = 200,
    summary="Get a user attribute",
    description=(
        "Returns the value of an allowed attribute for the authenticated user.  \n"
        "Handles special cases like `medals` or `interests_info`, returning already transformed data."
    ),
    operation_id="getUserAttribute",
    response_model=UserDataResponse,
    responses={
        401: {"model": ErrorResponse, "description": "Invalid or missing token, or unsupported attribute."},
        402: {"model": ErrorResponse, "description": "Database error or user not found."},
    },
)
def get_user(payload: UserAttribute) -> dict:
    ok, user_id = session.verify_session(payload.token)
    attribute = payload.attribute.strip()
    if not ok:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    if attribute not in GATHERING_ALLOWED_DATA_FIELDS:
        raise HTTPException(status_code = 401, detail = "Unsupported attribute")
    if attribute == "medals":
        try:
            medals = db.find_many(
                table_name="medals",
                filters={"user_id": user_id},
                projection={"_id": False, "timestamp": True, "medal": True},
            )
        except Exception:
            raise HTTPException(status_code=402, detail="Database error while fetching medals")
        medal_map = {
            entry["timestamp"]: entry.get("medal", [])
            for entry in medals
            if entry.get("timestamp")
        }
        return {"status": True, "medals": medal_map}
    user = db.find_one(
        table_name="users",
        filters = {"user_id": user_id},
        projection = {"_id": False, attribute: True}
    )
    if not user:
        raise HTTPException(status_code = 402, detail = "User not found")
    if attribute == "interests_info":
        raw_interests = user.get("interests_info") or user.get("selections_info") or []
        interests = []
        for idx in raw_interests:
            try:
                index = int(idx)
            except Exception:
                continue
            if 0 <= index < len(GATHERING_INTERESTS_LABELS):
                interests.append(GATHERING_INTERESTS_LABELS[index])
        return {"status": True, attribute: interests}
    return {"status": True, attribute: user.get(attribute, None)}

# ==========================
#            set
# ==========================
@router.post(
    "/set",
    status_code = 200,
    summary="Update a user attribute",
    description=(
        "Updates a single allowed attribute for the authenticated user (e.g., name, username, about).  \n"
        "Prevents username collisions and validates the session before writing to the database."
    ),
    operation_id="updateUserAttribute",
    response_model=UpdateUserResponse,
    responses={
        400: {"model": ErrorResponse, "description": "Invalid or missing token."},
        401: {"model": ErrorResponse, "description": "Unsupported attribute."},
        402: {"model": ErrorResponse, "description": "Database error while updating."},
        403: {"model": ErrorResponse, "description": "User not found."},
        409: {"model": ErrorResponse, "description": "Username already used by another user."},
    },
)
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
            values_dict={"$set": {attribute: payload.record}}
        )
    except PyMongoError:
        raise HTTPException(status_code = 402, detail = "Database error")
    if up_status.matched_count == 0:
            raise HTTPException(status_code = 403, detail = "User not found")
    return {"status": True, "attribute": attribute, "new_record": payload.record}

# ==========================
#         interests
# ==========================
@router.post(
    "/interests",
    status_code = 200,
    summary="Set user interests",
    description=(
        "Stores the interests selected by the authenticated user, mapping them to allowed labels.  \n"
        "Accepts only valid labels defined in configuration."
    ),
    operation_id="setUserInterests",
    response_model=StatusResponse,
    responses={
        400: {"model": ErrorResponse, "description": "Invalid interests format."},
        401: {"model": ErrorResponse, "description": "Invalid or missing token."},
        402: {"model": ErrorResponse, "description": "User not found."},
    },
)
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
@router.post(
    "/questions",
    status_code = 200,
    summary="Store questionnaire answers",
    description=(
        "Stores questionnaire answers (values between 0 and 4) for the authenticated user.  \n"
        "Validates the session and the answers format before persisting."
    ),
    operation_id="setUserQuestions",
    response_model=StatusResponse,
    responses={
        400: {"model": ErrorResponse, "description": "Invalid answers format (values out of range)."},
        401: {"model": ErrorResponse, "description": "Invalid or missing token."},
        402: {"model": ErrorResponse, "description": "User not found."},
    },
)
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
