import datetime
from typing import Optional
from fastapi import APIRouter, HTTPException
import uuid
from datetime import timezone as _tz

from pydantic import BaseModel
from email_validator import EmailNotValidError, validate_email
import utils.security as security
import utils.session as session
import utils.timing as timing
import db.database as db
UTC = _tz.utc

class LoginInput(BaseModel):
    username: str
    password: str

class LogOut(BaseModel):
    username: str
    token: str

class RegisterInput(BaseModel):
    username: str
    password: str
    email: str

class CheckBearer(BaseModel):
    username: Optional[str] = None
    token: str

router = APIRouter(prefix="/services/auth", tags=["auth"])

@router.post("/register", status_code = 200)
def register(payload: RegisterInput) -> dict:
    username = payload.username.strip()
    password = payload.password
    raw_email = payload.email.strip()
    # Check that all the fileds are in the payload
    if not username or not password or not raw_email:
        raise HTTPException(status_code = 400, detail = "Username/password/email are required")
    try:
        validated_email = validate_email(raw_email, check_deliverability = True)
        email = validated_email.email.lower()
    except EmailNotValidError as exc:
        raise HTTPException(status_code = 401, detail = f"Invalid email: {exc}")
    # Check that the password is good enough
    if not security.check_register_password(password):
        raise HTTPException(status_code = 402, detail = "Password does not meet complexity requirements")
    results = db.find_one(table_name = "users", filters = {"username": username}, projection = {"_id" : True})
    if results:
        raise HTTPException(status_code = 403, detail = "User already exists")
    email_exists = db.find_one(table_name = "users", filters = {"email": email}, projection = {"_id": True})
    if email_exists:
        raise HTTPException(status_code = 404, detail = "Email already in use")
    record = {
        "username": username,
        "password_hash": security.hash_password(password),
        "user_id": str(uuid.uuid4()),
        "email": email,
        "n_plans": 0,
        "n_plans_done": 0,
        "n_tasks_done": 0,
        "creation_time_account": timing.now(),
        "profile_pic": None,
        "streak": 0,
        "name": None,
        "surname": None,
        "height": None,
        "weight": None,
        "sex": None,
        "gathered_infos": [None for _ in range(20)],
        "medals": {},
    }
    try:
        db.insert(table_name = "users", record = record)
    except Exception as e:
        raise HTTPException(status_code = 500, detail = "Database error while creating user")
    token = session.generate_session(record["user_id"])
    return {"token": token, "username": username}

@router.post("/login", status_code = 200)
def login(payload: LoginInput) -> dict:
    username = payload.username.strip()
    password = payload.password
    # Check that all the fileds are in the payload
    if not username or not password:
        raise HTTPException(status_code = 400, detail = "Username and password are required")
    # Login
    user = db.find_one(table_name = "users", filters = {"username": username}, projection = {"_id" : False, "password_hash" : True, "user_id" : True})
    # Check if username and password are equals
    if user is None or not security.verify_password(user["password_hash"], password):
        raise HTTPException(status_code = 401, detail = "Invalid username or password")
    try:
        return {"token": session.generate_session(user["user_id"]), "username": username}
    except:
        return {"valid" : False}

@router.post("/logout", status_code = 200)
def logout(payload: LogOut) -> dict:
    token = payload.token
    username = payload.username.strip()
    if not token or not username:
        raise HTTPException(status_code = 400, detail = "Token and username required")
    ok, user_id = session.verify_session(token)
    if not ok or not user_id:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    user = db.find_one(
        table_name = "users",
        filters = {"user_id": user_id},
        projection = {"_id": False, "username": True}
    )
    username_in_db = user["username"] if user else None
    if username_in_db is None:
        raise HTTPException(status_code = 402, detail = "User not found")
    if username_in_db != username:
        raise HTTPException(status_code = 403, detail = "Username does not match token owner")
    # Logout
    ack = db.delete("sessions", {"token" : token})
    if ack.acknowledged:
        return {"valid": True}
    return {"valid": False}


@router.post("/check_bearer", status_code = 200)
def validate_bearer(payload: CheckBearer) -> dict:
    token = payload.token
    username = payload.username
    # Check if the token is present
    if not token:
        raise HTTPException(status_code = 400, detail = "Token required")
    ok, user_id = session.verify_session(token)
    if not ok or not user_id:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    # Check if the user exists
    proj_user_username = db.find_one(table_name = "users", filters = {"user_id": user_id}, projection = {"_id": False, "username": True})
    username_proj = proj_user_username["username"] if proj_user_username else None
    if username_proj is None:
        raise HTTPException(status_code = 402, detail = "User not found")
    # Check if the username is equal to the one associated with the token
    if username != username_proj:
        raise HTTPException(status_code = 403, detail = "Mismatch user id, username")
    return {"valid": True, "username": username_proj}
