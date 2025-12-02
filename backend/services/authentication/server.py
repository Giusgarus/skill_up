import logging
from typing import Optional
from fastapi import APIRouter, HTTPException
import uuid
from datetime import timezone as _tz
from pydantic import BaseModel, ConfigDict, Field
from validate_email import validate_email
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
    username: Optional[str] = Field(None, description="Username linked to the session, if provided.")
    token: Optional[str] = Field(None, description="Session token (Bearer) to validate or revoke.")

class Login(BaseModel):
    username: str = Field(..., description="Username chosen during registration.")
    password: str = Field(..., description="Account password.")

class Register(Login):
    email: str = Field(..., description="Valid email address that is not already used.")


class AuthResponse(BaseModel):
    model_config = ConfigDict(extra="allow")
    status: bool = Field(..., description="Indicates whether the authentication step succeeded.")
    token: Optional[str] = Field(None, description="New session token generated for the user.")
    username: Optional[str] = Field(None, description="Username associated with the generated token.")


class LogoutResponse(BaseModel):
    status: bool = Field(..., description="Outcome of the logout request.")
    valid: bool = Field(..., description="Whether the provided token was valid.")


class BearerValidationResponse(BaseModel):
    status: bool = Field(..., description="Outcome of the token verification.")
    valid: bool = Field(..., description="Whether the token is valid.")
    username: str = Field(..., description="Username associated with the verified token.")


class ErrorResponse(BaseModel):
    detail: str = Field(..., description="Error detail.")


# ===============================
#        Fast API Router
# ===============================
router = APIRouter(prefix="/services/auth", tags=["Auth"])



# ==============================================
# ================== ROUTES ====================
# ==============================================

# ==========================
#         register
# ==========================
@router.post(
    "/register",
    status_code=200,
    summary="Register a new account",
    description=(
        "Creates a new SkillUp user validating email, password strength, and username/email uniqueness.  \n"
        "- Validates the email with deliverability checks.  \n"
        "- Enforces existing password complexity rules.  \n"
        "- Generates a session token for the newly registered user."
    ),
    operation_id="registerUser",
    response_model=AuthResponse,
    responses={
        400: {"model": ErrorResponse, "description": "Username/password/email missing."},
        401: {"model": ErrorResponse, "description": "Invalid email."},
        402: {"model": ErrorResponse, "description": "Password does not meet complexity requirements."},
        403: {"model": ErrorResponse, "description": "Username already exists."},
        404: {"model": ErrorResponse, "description": "Email already in use."},
        500: {"model": ErrorResponse, "description": "Database error while creating the user."},
    },
)
def register(payload: Register) -> dict:
    username = str(payload.username).strip()
    password = payload.password
    raw_email = payload.email.strip().lower()
    # Check that all the fileds are in the payload
    if not username or not password or not raw_email:
        raise HTTPException(status_code = 400, detail = "Username/password/email are required")
    try:
        is_valid = validate_email(email_address=raw_email,check_format=True,check_blacklist=True,check_dns=True,dns_timeout=10,check_smtp=True,smtp_timeout=10)
    except Exception as exc:
        raise HTTPException(status_code = 401, detail = f"Invalid email:")
    if not is_valid:
        raise HTTPException(status_code = 401, detail = f"Invalid email:")
    # Check that the password is good enough
    if not security.check_register_password(password):
        raise HTTPException(status_code = 402, detail = "Password does not meet complexity requirements")
    results = db.find_one(table_name = "users", filters = {"username": username}, projection = {"_id" : True})
    if results:
        raise HTTPException(status_code = 403, detail = "User already exists")
    email_exists = db.find_one(table_name = "users", filters = {"email": raw_email}, projection = {"_id": True})
    if email_exists:
        raise HTTPException(status_code = 404, detail = "Email already in use")
    user = {
        "username": username,
        "password_hash": security.hash_password(password),
        "user_id": str(uuid.uuid4()),
        "email": raw_email,
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
@router.post(
    "/login",
    status_code=200,
    summary="Log in",
    description=(
        "Authenticates an existing user by verifying username and password.  \n"
        "Returns a new session token when credentials are correct."
    ),
    operation_id="loginUser",
    response_model=AuthResponse,
    responses={
        400: {"model": ErrorResponse, "description": "Username or password missing."},
        401: {"model": ErrorResponse, "description": "Invalid credentials."},
    },
)
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
@router.post(
    "/logout",
    status_code=200,
    summary="Log out",
    description=(
        "Revokes the provided session token and, when given, checks consistency with the username.  \n"
        "Detaches any linked notification device tokens."
    ),
    operation_id="logoutUser",
    response_model=LogoutResponse,
    responses={
        400: {"model": ErrorResponse, "description": "Token not provided."},
        401: {"model": ErrorResponse, "description": "Invalid or missing token."},
        402: {"model": ErrorResponse, "description": "User not found."},
        403: {"model": ErrorResponse, "description": "Username does not match the token owner."},
    },
)
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
@router.post(
    "/check_bearer",
    status_code=200,
    summary="Validate bearer token",
    description=(
        "Checks that the Bearer token is valid and, if provided, that the username matches the one associated.  \n"
        "Returns the canonical username tied to the token."
    ),
    operation_id="checkBearer",
    response_model=BearerValidationResponse,
    responses={
        400: {"model": ErrorResponse, "description": "Token not provided."},
        401: {"model": ErrorResponse, "description": "Invalid or missing token."},
        402: {"model": ErrorResponse, "description": "User not found."},
        403: {"model": ErrorResponse, "description": "Username does not match the token owner."},
    },
)
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
