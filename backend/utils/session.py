import secrets
import datetime
from fastapi import HTTPException
from pymongo import errors as pymongo_errors  # type: ignore
import backend.db.database as db
import backend.utils.security as security
import backend.utils.timing as timing


def generate_token() -> str:
    return secrets.token_urlsafe(48) # 256-bit+ token, URL-safe

def get_session(token: str) -> tuple[str, str]:
    session = db.find_one(
        table_name="sessions",
        filters={"token": token}
    )
    if not session:
        raise HTTPException(status_code=401, detail="Invalid or expired session token.")
    return session

def generate_session(user_id: str) -> str:
    for _ in range(6):
        token = security.generate_token()
        try:
            db.insert(
                table_name="sessions",
                record={"token": token, "user_id": user_id, "created_at": timing.now()}
            )
            return token
        except pymongo_errors.DuplicateKeyError:
            token = None
    else:
        raise HTTPException(status_code = 500, detail = "Could not create a session token")
    
def verify_session(token: str):
    session = db.find_one(
        table_name = "sessions",
        filters = {"token": token},
        projection = {"_id" : False, "user_id" : True}
    )
    if not session or not session["user_id"]:
        return [False, ""]
    return [True, session["user_id"]]