from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
import backend.db.database as db
import backend.utils.session as session


class GetLeaderboard(BaseModel):
    token: str


router = APIRouter(prefix="/services/gamification", tags=["gamification"])


@router.post("/leaderboard", status_code = 200)
def get_leaderboard(payload: GetLeaderboard) -> dict:
    ok, _ = session.verify_session(payload.token)
    if not ok:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    leaderboard_doc = db.find_one(table_name = "leaderboard", filters = {"_id": "topK"}, projection = {"_id": False, "items": True})
    items = (leaderboard_doc or {}).get("items", [])
    return {"status": True, "leaderboard": items}

'''
# per giorni senza task: non inserire nulla
# per giorni con task (non fatti): tutto None
# per giorni con task (fatti): medaglie/a presenti/e
"medals" : {"daily iso timestamp" : {"B": "timestamp"|None, "S": "timestamp"|None, "G": "timestamp"|None}},
# trigger mongo o segnale orologio controlla ogni mezzanotte se nell'ultima data e' stato fatto un task.
# caso data di oggi presente e medaglia presente: +1,
# caso data di oggi non e' presente: +0
# caso 
"streak": 0+1+1 = 0,
'''