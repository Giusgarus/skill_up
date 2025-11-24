import logging
from typing import Optional
from fastapi import APIRouter, HTTPException
import uuid
from datetime import timezone as _tz
from pydantic import BaseModel
from email_validator import EmailNotValidError, validate_email
import backend.utils.security as security
import backend.utils.session as session
import backend.utils.timing as timing
import backend.db.database as db
UTC = _tz.utc

logger = logging.getLogger("auth_service")


# ==============================
#        Payload Classes
# ==============================
class User(BaseModel):
    username: Optional[str] = None
    token: Optional[str] = None

class Login(BaseModel):
    username: str
    password: str

class Register(Login):
    email: str


# ===============================
#        Fast API Router
# ===============================
router = APIRouter(prefix="/services/auth", tags=["auth"])



# ==============================================
# ================== ROUTES ====================
# ==============================================

# ==========================
#         register
# ==========================
@router.post("/register", status_code=200)
def register(payload: Register) -> dict:
    username = str(payload.username).strip()
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
    user = {
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
        "score": 0,
        "name": None,
        "surname": None,
        "height": None,
        "weight": None,
        "sex": None,
        "interests_info": [],
        "selections_info": [],
        "questions_info": [None for _ in range(10)],
        "active_plans": [],
        "about": None,
        "day_routine": None,
        "organized": None,
        "focus": None,
        "age": None,
        "onboarding_answers": None,
        "medals": {},
    }
    try:
        db.insert(table_name = "users", record = user)
    except Exception as e:
        raise HTTPException(status_code = 500, detail = "Database error while creating user")
    token = session.generate_session(user["user_id"])
    return {"status": True, "token": token, "username": username}
    

# ==========================
#           login
# ==========================
@router.post("/login", status_code=200)
def login(payload: Login) -> dict:
    username = str(payload.username).strip()
    password = payload.password
    # Check that all the fileds are in the payload
    if not username or not password:
        raise HTTPException(status_code=400, detail="Username and password are required")
    # Login
    user = db.find_one(table_name="users", filters={"username": username}, projection={"_id": False, "password_hash": True, "user_id": True})
    # Check if username and password are equals
    if user is None or not security.verify_password(user["password_hash"], password):
        raise HTTPException(status_code=401, detail="Invalid username or password")
    try:
        return {"status": True, "token": session.generate_session(user["user_id"]), "username": username}
    except:
        return {"status": False}


# ==========================
#          logout
# ==========================
@router.post("/logout", status_code=200)
def logout(payload: User) -> dict:
    token = payload.token
    username = str(payload.username).strip() if payload.username else None
    if not token:
        raise HTTPException(status_code=400, detail="Token required")
    ok, user_id = session.verify_session(token)
    if not ok or not user_id:
        raise HTTPException(status_code=401, detail="Invalid or missing token")
    if username:
        user = db.find_one(
            table_name="users",
            filters={"user_id": user_id},
            projection={"_id": False, "username": True}
        )
        username_in_db = user["username"] if user else None
        if username_in_db is None:
            raise HTTPException(status_code=402, detail="User not found")
        if username_in_db != username:
            raise HTTPException(status_code=403, detail="Username does not match token owner")
    # Logout
    ack = db.delete("sessions", {"token": token})
    if ack.acknowledged:
        try:
            collection = db.connect_to_db()["device_tokens"]
        except Exception as exc:
            logger.warning("Unable to reach device_tokens collection: %s", exc)
            return {"valid": True, "status": True}
        try:
            collection.update_many(
                {"session_token": token},
                {"$unset": {"user_id": "", "username": "", "session_token": ""}},
            )
        except Exception as exc:
            logger.warning("Failed to detach device tokens for session during logout: %s", exc)
        return {"valid": True, "status": True}
    return {"valid": False, "status": False}


# ==========================
#       check_bearer
# ==========================
@router.post("/check_bearer", status_code=200)
def validate_bearer(payload: User) -> dict:
    token = payload.token
    username = str(payload.username).strip() if payload.username else None
    # Check if the token is present
    if not token:
        raise HTTPException(status_code=400, detail="Token required")
    ok, user_id = session.verify_session(token)
    if not ok or not user_id:
        raise HTTPException(status_code=401, detail="Invalid or missing token")
    # Check if the user exists
    proj_user_username = db.find_one(table_name="users", filters={"user_id": user_id}, projection={"_id": False, "username": True})
    username_proj = proj_user_username["username"] if proj_user_username else None
    if username_proj is None:
        raise HTTPException(status_code=402, detail="User not found")
    # Check if the username is equal to the one associated with the token if provided
    if username and username != username_proj:
        raise HTTPException(status_code=403, detail="Mismatch user id, username")
    return {"valid": True, "username": username_proj, "status": True}
