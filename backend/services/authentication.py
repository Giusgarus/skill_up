import datetime
from fastapi import APIRouter, Depends, HTTPException
from motor.motor_asyncio import AsyncIOMotorDatabase
import uuid
import backend.db.client as client
import utils.security as security
import utils.session as session

router = APIRouter(prefix="/services/auth", tags=["auth"])

@router.post("/register", status_code=201)
async def register(payload: dict) -> dict:
    if not payload.username or not payload.password:
        raise HTTPException(status_code = 400, detail = "Username and password are required")
    if client.get_collection("users").find_one({"username": payload.username}):
        raise HTTPException(status_code = 401, detail = "User already exists")
    if not security.check_register_password(payload.password):
        raise HTTPException(status_code = 402, detail = "Password does not meet complexity requirements")
    user_id = str(uuid.uuid4())
    password_hash = security.hash_password(payload.password)
    try:
        client.get_collection("users").insert_one({"username": payload.username, "password_hash": password_hash, "user_id": user_id, "user_mail" : payload.email})
        client.get_collection("user_data").insert_one({"user_id": user_id, "info": payload.user_info, "score" : 0, "creation_time" : datetime.datetime.now(UTC)})
        token = session.generate_session(user_id)
        return {"token": token, "username": payload.username}
    except:
        return {}

@router.post("/login", tags=["login"])
def login(payload: dict) -> dict:
    payload.username = payload.username.strip()
    if not payload.username or not payload.password:
        raise HTTPException(status_code = 400, detail = "Username and password are required")
    user = client.get_collection("users").find_one({"username": payload.username})
    if not user or not security.verify_password(user.get("password_hash", ""), payload.password):
        raise HTTPException(status_code = 401, detail = "Invalid username or password")
    try:
        return {
            "token": session.generate_session(user.user_id),
            "username": payload.username
        }
    except:
        return {}

@router.post("/check_bearer")
def validate_bearer(payload: dict) -> dict:
    token = payload.token.strip()
    username_hint = (payload.username or "").strip()
    if not token:
        raise HTTPException(status_code = 400, detail = "Token required")
    ok, user_id = verify_session(token)
    if not ok or not user_id:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    user = user_collection.find_one({"user_id": user_id}, {"username": 1})
    if not user:
        raise HTTPException(status_code = 404, detail = "User not found")
    resolved_username = user.get("username", "").strip()
    if username_hint and username_hint != resolved_username:
        raise HTTPException(status_code = 401, detail = "Mismatch user id, username")
    return {"valid": True, "username": resolved_username}

@router.get("/{user_id}")
def get_user(user_id: str):
    user = client.get_collection("users").find_one({"id": user_id})
    if not user:
        raise HTTPException(404, "Not found")
    return user
