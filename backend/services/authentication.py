from fastapi import APIRouter, Depends, HTTPException
from motor.motor_asyncio import AsyncIOMotorDatabase
import backend.db.client as client
import utils.security as security

router = APIRouter(prefix="/services/auth", tags=["auth"])

@router.post("/register", status_code=201)
async def register_user(payload: dict) -> dict:
    if not payload.username or not payload.password:
        raise HTTPException(status_code = 400, detail = "Username and password are required")
    if client.get_collection("users").find_one({"username": payload.username}):
        raise HTTPException(status_code = 401, detail = "User already exists")
    if not security.check_register_password(payload.password):
        raise HTTPException(status_code = 402, detail = "Password does not meet complexity requirements")
    user_id = str(uuid.uuid4())
    password_hash = security.hash_password(payload.password)
    try:
        client.get_collection("users").insert_one({"username": username, "password_hash": password_hash, "user_id": user_id, "user_mail" : email})
        client.get_collection("user_data").insert_one({"user_id": user_id, "info": user_info, "score" : 0, "creation_time" : datetime.datetime.now(UTC)})
        token = security.generate_session(user_id)
        return {"token": token, "username": payload.username}
    except:
        return {}
    return {"id": user_id}

@router.post("/login", status_code = 201)
def login_user(payload: dict) -> dict:

    username = creds.username.strip()
    if not username or not creds.password:
        raise HTTPException(status_code = 400, detail = "Username and password are required")
    user = client.get_collection("users").find_one({"username": username})
    if not user or not verify_password(user.get("password_hash", ""), creds.password):
        raise HTTPException(status_code = 401, detail = "Invalid username or password")
    user_id = user["user_id"]
    try:
        token = generate_session(user_id)
        return {"token": token, "username": username}
    except:
        return {}

@router.get("/{user_id}")
def get_user(user_id: str):
    db = get_db()
    user = db["users"].find_one({"id": user_id})
    if not user:
        raise HTTPException(404, "Not found")
    return user

def register() -> str:
    if not username or not password:
        raise HTTPException(status_code = 400, detail = "Username and password are required")
    if user_collection.find_one({"username": username}):
        raise HTTPException(status_code = 401, detail = "User already exists")
    if not check_register_password(password):
        raise HTTPException(status_code = 402, detail = "Password does not meet complexity requirements")
    user_id = str(uuid.uuid4())
    password_hash = hash_password(password)
    try:
        user_collection.insert_one({"username": username, "password_hash": password_hash, "user_id": user_id, "user_mail" : email})
        user_data_collection.insert_one({"user_id": user_id, "info": user_info, "score" : 0, "creation_time" : datetime.datetime.now(UTC)})
        token = generate_session(user_id)
        return {"token": token, "username": username}
    except:
        return {}
    return user_id

def login():
    pass

def auth():
    pass