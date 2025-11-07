import secrets
import datetime
from fastapi import HTTPException
from pymongo import errors as pymongo_errors  # type: ignore
import backend.db.database as db
import backend.utils.security as security
import backend.utils.utility as utility


def generate_token() -> str:
    return secrets.token_urlsafe(48) # 256-bit+ token, URL-safe

def verify_session(token: str):
    session = db.find(
        table_name="sessions",
        filters={"token": token}
    )
    if not session:
        return [False, ""]
    return [True, session.get("user_id")]

def generate_session(user_id: str) -> str:
    for _ in range(6):
        token = security.generate_token()
        try:
            db.insert(
                table_name="sessions",
                record={"token": token, "user_id": user_id, "created_at": utility.get_now_timestamp()}
            )
            return token
        except pymongo_errors.DuplicateKeyError:
            token = None
    else:
        raise HTTPException(status_code = 500, detail = "Could not create a session token")