import secrets
import datetime
from fastapi import HTTPException
from pymongo import errors as pymongo_errors  # type: ignore
from datetime import timezone as _tz
import backend.db.client as client
import backend.utils.security as security
UTC = _tz.utc

def generate_token() -> str:
    return secrets.token_urlsafe(48) # 256-bit+ token, URL-safe

def verify_session(token: str):
    session = client.get_collection("sessions").find_one({"token": token})
    if not session:
        return [False, ""]
    return [True, session.get("user_id")]

def generate_session(user_id: str) -> str:
    for _ in range(6):
        token = security.generate_token()
        try:
            client.get_collection("sessions").insert_one({"token": token, "user_id": user_id, "created_at": datetime.datetime.now(UTC)})
            return token
        except pymongo_errors.DuplicateKeyError:
            token = None
    else:
        raise HTTPException(status_code = 500, detail = "Could not create a session token")