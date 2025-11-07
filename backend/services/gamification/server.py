from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
import backend.db.database as db
import backend.utils.session as session

LEADERBOARD_K = 10

class GetLeaderboard(BaseModel):
    token: str


router = APIRouter(prefix="/services/gamification", tags=["gamification"])

@router.post("/leaderboard", status_code = 201)
def leaderboard_get(payload: GetLeaderboard) -> dict:
    ok, _ = session.verify_session(payload.token)
    if not ok:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    record = db.find_one(
        table_name="leaderboard",
        filters={"_id": "topK"},
        projection = {"_id": False, "items": True}
    )
    items = (record or {}).get("items", [])
    return {"status": True, "leaderboard": items}