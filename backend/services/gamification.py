from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
import backend.db.client as client
import backend.utils.session as session
router = APIRouter(prefix="/services/gamification", tags=["gamification"])

class GetLeaderboard(BaseModel):
    token: str

@router.post("/leaderboard", status_code = 201)
def leaderboard_get(payload: GetLeaderboard) -> dict:
    ok, _ = session.verify_session(payload.token)
    if not ok:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    leaderboard_coll = client.get_collection("leaderboard")
    if leaderboard_coll is None:
        raise HTTPException(status_code = 503, detail = "DB unavailable")
    leaderboard_doc = leaderboard_coll.find_one({"_id": "topK"}, projection = {"_id": False, "items": True})
    items = (leaderboard_doc or {}).get("items", [])
    return {"status": True, "leaderboard": items}