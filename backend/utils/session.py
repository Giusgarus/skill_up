import secrets
import datetime
from fastapi import HTTPException
from pymongo import errors as pymongo_errors  # type: ignore
from datetime import timezone as _tz
import backend.db.database as db
import backend.utils.security as security
UTC = _tz.utc

def get_now_timestamp():
    return datetime.datetime.now(UTC)

def generate_token() -> str:
    return secrets.token_urlsafe(48) # 256-bit+ token, URL-safe

def verify_session(token: str):
    session = db.find_one(table_name = "sessions", filters = {"token": token}, projection = {"_id" : False, "user_id" : True})
    user_id = session["user_id"] if session else None
    if not user_id:
        return [False, ""]
    return [True, user_id]

def generate_session(user_id: str) -> str:
    for _ in range(6):
        token = security.generate_token()
        try:
            db.insert(table_name = "sessions", record = {"token": token, "user_id": user_id, "created_at": get_now_timestamp()})
            return token
        except pymongo_errors.DuplicateKeyError:
            token = None
    else:
        raise HTTPException(status_code = 500, detail = "Could not create a session token")