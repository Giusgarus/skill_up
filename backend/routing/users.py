from fastapi import APIRouter, Depends
from motor.motor_asyncio import AsyncIOMotorDatabase
from backend.db.client import get_db
from backend.schemas.users import UserCreate

router = APIRouter(prefix="/users", tags=["users"])

@router.post("", status_code=201)
async def create_user(payload: UserCreate, db: AsyncIOMotorDatabase = Depends(get_db)):
    from backend.services.authentication import registration
    user_id = await registration(db, payload.email, payload.password)
    return {"id": user_id}