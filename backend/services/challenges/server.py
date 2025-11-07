from typing import Set, Annotated
from pydantic import BaseModel, StringConstraints
from fastapi import APIRouter, Depends, HTTPException, Query
import backend.db.database as db
import backend.utils.session as session
import backend.utils.timing as timing

MIN_HEAP_K_LEADER = 10
ALLOWED_DATA_FIELDS: Set[str] = {"score", "name", "surname", "height", "weight", "sex", "info1", "info2", "info3", "info4"}
MIN_LEN_ADF = 1
MAX_LEN_ADF = 500

RecordStr = Annotated[
    str,
    StringConstraints(
        strip_whitespace = True,
        min_length = MIN_LEN_ADF,
        max_length = MAX_LEN_ADF,
        pattern = r"^[A-Za-z0-9_]+$",
    ),
]

class UpdateUserBody(BaseModel):
    token: str 
    attribute: str
    record: RecordStr

class SetTaskDone(BaseModel):
    token: str
    task_id: int

class GeneratePlan(BaseModel):
    token: str
    plan: str


router = APIRouter(prefix="/services/challenges", tags=["challenges"])

@router.get("/plan", status_code=201)
def get_plan(user_id: str = Query(...), date: str = Query(...), db = Depends(db.connect_to_db)):
    if db is None:
        raise HTTPException(status_code=503, detail="DB unavailable")
    pass

@router.post("/task_done", status_code=201)
def task_done(payload: dict) -> dict:
    token = payload["token"]
    now = timing.now_iso()
    task_id = payload["task_id"]
    user_id = payload["user_id"]
    record = db.find_one(
        table_name="tasks",
        filters={"task_id": task_id, "user_id": user_id}
    )
    # Modifica il task e reinseriscilo nel DB (fai una update sul campo task_done o quello che e')

    return {}

@router.post("/set_user", status_code=201)
def set_user(payload: dict):
    if "user_id" not in payload.keys():
        raise HTTPException(status_code=401, detail=f"The primary key of 'users' is not in: {payload.keys()}")
    return db.update(
        table_name="users",
        record=payload
    )

@router.get("/prompt", status_code=201)
def get_llm_response(payload: dict) -> dict:
    username = payload.username
    token = payload.token
    prompt = payload.prompt
    valid_token, user_id = session.verify_session(token)
    if not valid_token:
        raise HTTPException(status_code=401, detail="Invalid or missing token")
    results = db.find(
        table_name="user_data",
        filters={"user_id": user_id}
    )
    user_info = results["data"][0]
    if not user_info:
        user_info = {}
    # Qui dovresti implementare la chiamata al server di mos --> HTTP/JSON request
    llm_response = send_json_to_llm_server({
        "prompt": prompt,
        "user_info": user_info
    })
    return {"llm_response": llm_response}