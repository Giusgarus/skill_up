import datetime
from fastapi import APIRouter, HTTPException
import uuid
from datetime import timezone as _tz
import backend.db.client as client
import utils.security as security
import utils.session as session
import db.database as db
UTC = _tz.utc

router = APIRouter(prefix="/services/auth", tags=["auth"])

@router.post("/register", status_code=201)
async def register(payload: dict) -> dict:
    if not payload["username"] or not payload["password"]:
        raise HTTPException(status_code = 400, detail = "Username and password are required")
    if not security.check_register_password(payload["password"]):
        raise HTTPException(status_code = 402, detail = "Password does not meet complexity requirements")
    results = db.query(table_name="users", filters={"username": payload["username"]})
    if results["data"]:
        raise HTTPException(status_code = 401, detail = "User already exists")
    user_id = str(uuid.uuid4())
    password_hash = security.hash_password(payload["password"])
    try:
        db.insert(
            table_name="users",
            record={"username": payload["username"], "password_hash": password_hash, "user_id": user_id, "user_mail" : payload["email"]}
        )
        db.insert(
            table_name="user_data",
            record={"user_id": user_id, "info": payload["user_info"], "score" : 0, "creation_time" : datetime.datetime.now(UTC)}
        )
        token = session.generate_session(user_id)
        return {"token": token, "username": payload["username"]}
    except:
        return {}

@router.post("/login", tags=["login"])
def login(payload: dict) -> dict:
    payload["username"] = payload["username"].strip()
    if not payload["username"] or not payload["password"]:
        raise HTTPException(status_code = 400, detail = "Username and password are required")
    results = db.query(
        table_name="users",
        filters={"username": payload["username"]}
    )
    user = results["data"][0]
    if not user or not security.verify_password(user["password_hash"], payload["password"]):
        raise HTTPException(status_code = 401, detail = "Invalid username or password")
    try:
        return {
            "token": session.generate_session(user.get("user_id", "")),
            "username": payload["username"]
        }
    except:
        return {}

@router.post("/check_bearer", tags=["check_bearer"])
def validate_bearer(payload: dict) -> dict:
    token = payload.token.strip()
    username_hint = (payload["username"] or "").strip()
    if not token:
        raise HTTPException(status_code = 400, detail = "Token required")
    ok, user_id = session.verify_session(token)
    if not ok or not user_id:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    results = db.query(
        table_name="users",
        record={"user_id": user_id},
        projection={"username": 1}
    )
    try:
        user = results["data"][0]
    except Exception:
        raise HTTPException(status_code = 404, detail = f"User not found:\n{results["error"]}")
    resolved_username = user.get("username", "").strip()
    if username_hint and username_hint != resolved_username:
        raise HTTPException(status_code = 401, detail = "Mismatch user id, username")
    return {"valid": True, "username": resolved_username}

@router.get("/{user_id}")
def get_user(user_id: str):
    results = db.query(
        table_name="users",
        filters={"id": user_id}
    )
    user = results["data"][0]
    if not user:
        raise HTTPException(404, "Not found")
    return user
