import logging
from statistics import mean
from fastapi import APIRouter, HTTPException
import backend.db.database as db
import backend.utils.session as session
import backend.utils.timing as timing
from pydantic import BaseModel, StringConstraints
from typing import Annotated, Set
from pymongo.errors import PyMongoError
from pymongo import ReturnDocument
from utils.session import *
import utils.llm_interaction as llm
import utils.data_handler as dh

logger = logging.getLogger(__name__)

MIN_HEAP_K_LEADER = 10
ALLOWED_DATA_FIELDS: Set[str] = {"score", "name", "surname", "height", "weight", "sex", "profile_pic"} | {f"info{i}" for i in range(20)}
MIN_LEN_ADF = 1
MAX_LEN_ADF = 200000
DIFFICULTY_MAP = {"easy" : 1, "medium" : 3, "hard": 5}
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
    goal: str

class DeletePlan(BaseModel):
    token: str
    plan_id: str


router = APIRouter(prefix="/services/challenges", tags=["challenges"])


@router.post("/plan/delete", status_code = 200)
def delete_plan(payload: DeletePlan) -> dict:
    plan_id = payload.plan_id
    ok, user_id = session.verify_session(payload.token)
    if not ok or not user_id:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    res = db.update_one("plans", keys_dict = {"user_id" : user_id, "plan_id" : plan_id}, values_dict = {"$set" : {"deleted" : True}})
    if res.matched_count == 0:
        raise HTTPException(status_code = 402, detail = "Invalid Plan in Tables")
    return {"valid" : True}
    

@router.post("/task_done", status_code = 200)
def task_done(payload: SetTaskDone) -> dict:
    ok, user_id = session.verify_session(payload.token)
    if not ok or not user_id:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    
    # 1. Update tasks
    task_id = payload.task_id
    if not task_id:
        raise HTTPException(status_code = 402, detail = "Invalid Task ID")
    proj_task = db.find_one_and_update(
        table_name = "tasks",
        keys_dict = {"task_id" : task_id, "user_id" : user_id, "plan_id" : payload.plan_id}, 
        values_dict = {"$set": {"completed_at": timing.now()}}, 
        projection = {"_id" : False, "score" : True}, 
        return_policy = ReturnDocument.AFTER
    )

    # 2. Update users
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
    
    # 3. Update plan
    plan_id = payload.plan_id
    if not plan_id:
        raise HTTPException(status_code = 403, detail = "Invalid Plan ID")
    plan = db.find_one_and_update(
        table_name = "plans",
        keys_dict = {"user_id": user_id, "plan_id": plan_id},
        values_dict = {"$inc": {"n_tasks_done": 1}}
    )
    if plan["n_tasks_done"] == plan["n_tasks"]: # case of plan completed
        db.update_one(
            table_name = "plans",
            keys_dict = {"user_id": user_id, "plan_id": plan_id},
            values_dict = {"$set": {"completed_at": timing.now_iso()}}
        )
    if plan.matched_count == 0:
        raise HTTPException(status_code = 406, detail = "Invalid increment in plan")
    
    # 4. Update medals
    if payload.medal_taken != "None":
        plan = db.update_one(
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
        if plan.matched_count == 0:
            raise HTTPException(status_code = 407, detail = "Invalid medal passed")
        
    # 5. Update leaderboard
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
        up_status = db.update_one(
            table_name="users",
            keys_dict={"user_id" : user_id},
            values_dict={"$set": {f"gathered_info.{payload.attribute}": payload.record}}
        )
        if up_status.matched_count == 0:
            raise HTTPException(status_code = 402, detail = "User not found")
    except PyMongoError: 
        raise HTTPException(status_code = 403, detail = "Database error")
    return {"updated": True, "new_record": payload.record}



@router.post("/prompt", status_code=200)
def get_llm_response(payload: GeneratePlan) -> dict:
    token = payload.token
    user_goal = payload.goal

    # 1. Verify Session
    valid_token, user_id = session.verify_session(token)
    if not valid_token:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    
    # 2. Get User Data (Goal, Level and History)
    user_info = dh.get_user_info(user_id)
    
    # 3. Communication with LLM server --> expected response: {"ok": True, "result": {"n_tasks": ..., "tasks": ...}}
    llm_payload = {
        "goal": user_goal,
        "level": "0", # Default to beginner (0=beginner, 1=intermediate, 2=advanced)
        "history": [], # empty because we haven't previous prompts/responses for this plan (because has to be created now)
        "user_info": user_info
    }
    llm_resp = llm.get_llm_response(llm_payload)
    if not llm_resp.get("ok"):
        err_msg = llm_resp.get("error", "Unknown error from LLM service")
        logger.error("LLM service error for user %s: %s", user_id, err_msg)
        raise HTTPException(status_code=502, detail=f"LLM service error: {err_msg}")

    # 4. Update Database --> we store the whole structure now
    plan_id = db.find_one_and_update(
        table_name="users", 
        keys_dict = {"user_id" : user_id}, 
        values_dict = {"$inc" : {"n_plans" : 1}}, 
        projection = {"_id" : False, "n_plans" : True},
        return_policy = ReturnDocument.BEFORE
    )
    plan = {
        "plan_id" : plan_id,
        "user_id" : user_id,
        "n_tasks" : len(llm_resp["result"]["tasks"]),
        "reponses": [],
        "prompts": [],
        "deleted": False,
        "difficulty": round(mean([DIFFICULTY_MAP.get(task["difficulty"], 1) for _, task in dict(llm_resp["result"]["tasks"]).items()])), # mean of difficulties of all the tasks
        "n_tasks_done": 0,
        "created_at": timing.now_iso(),
        "expected_complete": timing.get_last_date(list(dict(llm_resp["result"]["tasks"]).keys())), # get the higher date in the tasks dict
        "tasks": {date: [task] for date, task in dict(llm_resp["result"]["tasks"]).items()} # {"date1": [task], "date2": [task], ...}
    }
    db.insert("plans", plan)
    records = []
    for i, date_task in enumerate(dict(llm_resp["result"]["tasks"]).items()):
        date, task = date_task
        timing.from_iso_to_datetime(date)
        records.append({
            "task_id": i,
            "plan_id": plan_id,
            "user_id": user_id,
            "title": task["title"],
            "description": task["description"],
            "difficulty": DIFFICULTY_MAP.get(task["difficulty"]),
            "score": DIFFICULTY_MAP.get(task["difficulty"].lower(), "1") * 10,
            "deadline_date": date,
            "completed_at": None
        })
    db.insert_many("tasks", records)
    
    return {"ok": True, "data": llm_resp["result"], "prompt": llm_resp["prompt"]}