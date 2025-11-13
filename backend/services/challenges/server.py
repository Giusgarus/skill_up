from fastapi import APIRouter, Depends, HTTPException, Query, status
import backend.db.database as db
import backend.db.client as client
import backend.utils.session as session
import backend.utils.timing as timing
from pydantic import BaseModel, StringConstraints, constr
from typing import Annotated, Any, Set
from pymongo.errors import PyMongoError
from pymongo import ReturnDocument

MIN_HEAP_K_LEADER = 10
ALLOWED_DATA_FIELDS: Set[str] = {"score", "name", "surname", "height", "weight", "sex", "profile_pic"} | {f"info{i}" for i in range(20)}
MIN_LEN_ADF = 1
MAX_LEN_ADF = 200000
ALLOWED_DATA_MEDALS: Set[str] = {"B","S","G","None"}

RecordStr = Annotated[
    str,
    StringConstraints(
        strip_whitespace = True,
        min_length = MIN_LEN_ADF,
        max_length = MAX_LEN_ADF,
        pattern = r"^[\x20-\x7E]+$",
    )
]

class UpdateUserBody(BaseModel):
    token: str 
    attribute: str
    record: RecordStr

class SetTaskDone(BaseModel):
    token: str
    plan_id: str
    task_id: int
    medal_taken: str

class GeneratePlan(BaseModel):
    token: str
    plan: str

router = APIRouter(prefix="/services/challenges", tags=["challenges"])

@router.post("/task_done", status_code = 200)
def task_done(payload: SetTaskDone) -> dict:
    ok, user_id = session.verify_session(payload.token)
    if not ok or not user_id:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    # Update tasks
    task_id = payload.task_id
    if not task_id:
        raise HTTPException(status_code = 402, detail = "Invalid Task ID")
    proj_task = db.find_one_and_update(
        table_name = "tasks",
        keys_dict = {"task_id" : task_id, "user_id" : user_id, "plan_id" : plan_id}, 
        values_dict = {"$set": {"completed_at": timing.now()}}, 
        projection = {"_id" : False, "score" : True}, 
        return_policy = ReturnDocument.AFTER
    )
    # Update users
    score = proj_task["score"] if proj_task else None
    if score is None:
        raise HTTPException(status_code = 404, detail = "Invalid score in Task ID")
    proj_user_data = db.find_one_and_update(
        table_name = "users",
        keys_dict = {"user_id": user_id},
        values_dict = {"$inc": {"n_tasks_done": 1, "data.score": score}},
        projection = {"_id": False, "username": True, "data.score": True}, 
        return_policy = ReturnDocument.AFTER
    )
    data_projection = proj_user_data["data"] if proj_user_data else {}
    new_score = (data_projection or {}).get("score")
    username = proj_user_data["username"] if proj_user_data else None
    if new_score is None or not username:
        raise HTTPException(status_code = 405, detail = "Invalid projection after updating user")
    # Update plan
    plan_id = payload.plan_id
    if not plan_id:
        raise HTTPException(status_code = 403, detail = "Invalid Plan ID")
    res = db.update_one(
        table_name = "plans",
        keys_dict = {"user_id": user_id, "plan_id": plan_id},
        values_dict = {"$inc": {"n_tasks_done": 1}}
    )
    if res.matched_count == 0:
        raise HTTPException(status_code = 406, detail = "Invalid increment in plan")
    # Update medals
    if payload.medal_taken != "None":
        res = db.update_one(
            table_name = "medals",
            keys_dict = {"user_id": user_id, "timestamp": timing.now().today()},
            values_dict = {
                "$push": {
                    "medal": {
                        "grade": payload.medal_taken,
                        "task_id": task_id
                    }
                }
            }
        )
        if res.matched_count == 0:
            raise HTTPException(status_code = 407, detail = "Invalid medal passed")
    # Leaderboard update
    db.update_one(
        table_name = "leaderboard",
        keys_dict = {"_id": "topK"},
        values_dict = {
            "$pull": {"items": {"username": username}},
            "$push": {
                "items": {
                    "$each": [{"username": username, "score": new_score}],
                    "$sort": {"score": -1, "username": 1},
                    "$slice": MIN_HEAP_K_LEADER
                }
            }
        }
    )
    return {"status" : True}

@router.post("/set", status_code = 200)
def update_user(payload: UpdateUserBody):
    valid_token, user_id = session.verify_session(payload.token)
    if not valid_token:
        raise HTTPException(status_code = 400, detail = "Invalid or missing token")
    if payload.attribute not in ALLOWED_DATA_FIELDS:
        raise HTTPException(status_code = 401, detail = "Unsupported attribute")
    try:
        up_status = db.update_one("users", {"user_id" : user_id}, {"$set": {f"data.{payload.attribute}": payload.record}})
        if up_status.matched_count == 0:
            raise HTTPException(status_code = 402, detail = "User not found")
    except PyMongoError: 
        raise HTTPException(status_code = 403, detail = "Database error")
    return {"updated": True, "new_record": payload.record}

@router.post("/prompt", status_code = 200)
def get_llm_response(payload: GeneratePlan) -> dict:
    token = payload.token
    prompt = payload.plan
    valid_token, user_id = session.verify_session(token)
    if not valid_token:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    results = db.find_one(table_name = "users", filters = {"user_id": user_id}, projection = {"_id": False, "data": True})
    if results == None:
        raise HTTPException(status_code = 402, detail = "Invalid user")
    user_info = results["data"] if results else None
    if not user_info:
        user_info = {}
    # Qui dovresti implementare la chiamata al server di mos --> HTTP/JSON request
    llm_response = send_json_to_llm_server({
        "prompt": prompt,
        "user_info": user_info
    })
    # Controlla risposta e aggiorna tutti i campi necessari 
    # ...
    # Create Medals with the empty timestamps
    return {}
