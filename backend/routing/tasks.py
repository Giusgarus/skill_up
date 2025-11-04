from fastapi import APIRouter, Depends, HTTPException, Query
from backend.db.client import get_db
from backend.services.challenge import generate_plan

router = APIRouter(prefix="/tasks", tags=["tasks"])

@router.get("/plan")
def get_plan(user_id: str = Query(...), date: str = Query(...), db = Depends(get_db)):
    if db is None:
        raise HTTPException(status_code=503, detail="DB unavailable")
    return generate_plan(db, user_id, date)