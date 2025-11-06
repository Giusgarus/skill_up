import datetime
from typing import Optional
from fastapi import APIRouter, HTTPException
import uuid
from datetime import timezone as _tz
import backend.db.client as client
import utils.security as security
import utils.session as session
import db.database as db
UTC = _tz.utc

class LoginInput(BaseModel):
    username: str
    password: str

class RegisterInput(BaseModel):
    username: str
    password: str
    email: str

class CheckBearer(BaseModel):
    username: Optional[str] = None
    token: str

router = APIRouter(prefix="/services/auth", tags=["auth"])

@router.post("/register", status_code=201)
def register(payload: RegisterInput) -> dict:
    username = payload.username.strip()
    email = payload.email.strip().lower()
    password = payload.password
    if not username or not password or not email:
        raise HTTPException(status_code = 400, detail = "Username/password/email are required")
    if not security.check_register_password(password):
        raise HTTPException(status_code = 402, detail = "Password does not meet complexity requirements")
    results = db.find_one(table_name = "users", filters = {"username": username}, projection = {"_id" : True})
    if results:
        raise HTTPException(status_code = 401, detail = "User already exists")
    user_id = str(uuid.uuid4())
    password_hash = security.hash_password(password)
    record = {
        "username": username,
        "password_hash": password_hash,
        "user_id": user_id,
        "email": email,
        "n_tasks_done": 0,
        "creation_time_account": datetime.datetime.now(UTC),
        "data": {
            "score": 0,
            "name": None, "surname": None,
            "height": None, "weight": None, "sex": None,
            "info1": None, "info2": None, "info3": None, "info4": None
        }
    }
    try:
        db.insert(table_name = "users", record = record)
    except Exception as e:
        raise HTTPException(status_code = 500, detail = "Database error while creating user")
    token = session.generate_session(user_id)
    return {"token": token, "username": username}

@router.post("/login", status_code=201)
def login(payload: LoginInput) -> dict:
    username = payload.username.strip()
    password = payload.password
    if not username or not password:
        raise HTTPException(status_code = 400, detail = "Username and password are required")
    user = db.find_one(table_name = "users", filters = {"username": username}, projection = {"_id" : False, "password_hash" : True, "user_id" : True})
    if user is None or not security.verify_password(user["password_hash"], password):
        raise HTTPException(status_code = 401, detail = "Invalid username or password")
    try:
        return {"token": session.generate_session(user["user_id"]), "username": username}
    except:
        return {"valid" : False}

@router.post("/check_bearer", status_code=201)
def validate_bearer(payload: CheckBearer) -> dict:
    token = payload.token
    username = payload.username
    if not token:
        raise HTTPException(status_code = 400, detail = "Token required")
    ok, user_id = session.verify_session(token)
    if not ok or not user_id:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    proj_user_username = db.find_one(table_name = "users", filters = {"user_id": user_id}, projection = {"_id": False, "username": True})
    username_proj = proj_user_username["username"] if proj_user_username else None
    if not username_proj:
        raise HTTPException(status_code = 402, detail = "User not found")
    if username != username_proj:
        raise HTTPException(status_code = 403, detail = "Mismatch user id, username")
    return {"valid": True, "username": username_proj}