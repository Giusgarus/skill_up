from fastapi import APIRouter, Depends, HTTPException
from motor.motor_asyncio import AsyncIOMotorDatabase
from backend.services.authentication import register, login, auth

router = APIRouter(prefix="/services/auth", tags=["users"])

@router.post("/register", status_code=201)
async def register_user(payload: dict) -> dict:
    user_id = await register(payload.email, payload.password)
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