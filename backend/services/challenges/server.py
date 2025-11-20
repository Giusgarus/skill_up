from fastapi import APIRouter, Depends, HTTPException, Query, status
import backend.db.database as db
import backend.db.client as client
import backend.utils.session as session
import backend.utils.timing as timing
from pydantic import BaseModel, StringConstraints, constr
from typing import Annotated, Any, Set
from pymongo.errors import PyMongoError
from pymongo import ReturnDocument
from utils.session import *

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
    plan: str

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

# add imports near the top of your file
import os
import time
import logging
from typing import Tuple, Dict, Any
import requests
from requests.adapters import HTTPAdapter, Retry
from fastapi import HTTPException

logger = logging.getLogger(__name__)

# ---------------------------
# Client that calls LLM server
# ---------------------------
LLM_SERVER_URL = os.getenv("LLM_SERVER_URL", "http://localhost:8001")
LLM_SERVICE_TOKEN = os.getenv("LLM_SERVICE_TOKEN", None)
LLM_TIMEOUT = float(os.getenv("LLM_TIMEOUT", "10"))  # seconds
LLM_MAX_RETRIES = int(os.getenv("LLM_MAX_RETRIES", "2"))
print("THE LLM SERVER URL IS: ", LLM_SERVER_URL)
def _requests_session_with_retries(retries: int = 2, backoff_factor: float = 0.3) -> requests.Session:
    s = requests.Session()
    retry = Retry(
        total=retries,
        read=retries,
        connect=retries,
        backoff_factor=backoff_factor,
        status_forcelist=(429, 502, 503, 504),
        allowed_methods=frozenset(["POST", "GET", "PUT", "DELETE", "OPTIONS"])
    )
    s.mount("https://", HTTPAdapter(max_retries=retry))
    s.mount("http://", HTTPAdapter(max_retries=retry))
    return s

def _minimal_validate_challenge(resp: Dict[str, Any]) -> Tuple[bool, str]:
    print(resp)
    """
    Return (is_valid, error_message_or_empty).
    Validates structure: 
    {
       "n_tasks": int,
       "task_list": { "date" :  {"title", "description", "difficulty"}, "date2" : {...} ... }
    }
    """
    if not isinstance(resp, dict):
        return False, "Response is not a JSON object"

    # 1. Validate Top Level Keys
    if "task_list" not in resp or not isinstance(resp["task_list"], list):
        return False, "Missing or invalid 'task_list'"
    
    if "n_tasks" not in resp or not isinstance(resp["n_tasks"], int):
        return False, "Missing or invalid 'n_tasks'"

    if len(resp["task_list"]) == 0:
        return False, "Challenge list is empty"

    # 2. Validate Individual Challenge Objects
    required_item_keys = ["title", "description", "difficulty"]
    
    for index, item in enumerate(resp["task_list"]):
        # Check Keys
        for k in required_item_keys:
            if k not in item:
                return False, f"Challenge #{index+1} missing key: {k}"
        
        # Check Types
        if not isinstance(item["title"], str) or not isinstance(item["description"], str):
            return False, f"Challenge #{index+1}: Title/description must be strings"
            
        if not isinstance(item["duration_minutes"], (int, float)):
            return False, f"Challenge #{index+1}: duration_minutes must be numeric"
            
        # Check Logic
        if item["difficulty"] not in ("Easy", "Medium", "Hard"):
            # Optional: Auto-fix here or reject. We reject for strictness.
            return False, f"Challenge #{index+1}: Invalid difficulty"

    return True, ""

def send_json_to_llm_server(payload: Dict[str, Any]) -> Dict[str, Any]:
    """
    payload expected keys: "goal" (str), "level", "history" (list)
    Returns: {"ok": True, "result": {...}} or {"ok": False, "error": "explain"}
    """
    url = LLM_SERVER_URL.rstrip("/") + "/generate-challenge"
    
    # --- DEBUG PRINT START ---
    print(f"DEBUG: send_json_to_llm_server received keys: {list(payload.keys())}")
    print(f"DEBUG: payload['goal'] raw value: '{payload.get('goal')}'")
    # --- DEBUG PRINT END ---

    # 1. Robust Goal Extraction
    # We check if 'goal' exists and is not None/Empty. If it is, we try 'prompt'.
    goal_text = payload.get("goal")
    if not goal_text: 
        goal_text = payload.get("prompt")

    # 2. Robust History Extraction
    history_data = payload.get("history")
    if history_data is None:
        history_data = payload.get("user_info", {}).get("history", [])

    # 3. Prepare Body
    # Ensure we don't convert None to "None" string.
    final_goal_str = str(goal_text).strip() if goal_text else ""

    body = {
        "goal": final_goal_str,
        "level": payload.get("level", "Beginner"),
        "user_info" : payload["user_info"],
        "history": history_data
    }

    # 4. The Check that was failing
    if not body["goal"]:
        logger.error(f"Validation Error: Goal came in as '{goal_text}', became '{final_goal_str}'")
        return {"ok": False, "error": "Empty goal/prompt provided"}

    headers = {"Content-Type": "application/json"}
    if LLM_SERVICE_TOKEN:
        headers["Authorization"] = f"Bearer {LLM_SERVICE_TOKEN}"

    session = _requests_session_with_retries(retries=LLM_MAX_RETRIES)
    try:
        logger.info("Calling LLM server %s (goal len=%d)", url, len(body["goal"]))
        resp = session.post(url, json=body, timeout=LLM_TIMEOUT, headers=headers)
    except requests.RequestException as e:
        logger.error("Error contacting LLM server: %s", e, exc_info=True)
        return {"ok": False, "error": f"LLM server unreachable: {str(e)}"}

    if resp.status_code != 200:
        content_snippet = (resp.text[:500] + "...") if resp.text else ""
        logger.warning("LLM server returned status %d: %s", resp.status_code, content_snippet)
        return {"ok": False, "error": f"LLM server error ({resp.status_code})"}

    try:
        result = resp.json()
    except ValueError:
        logger.error("LLM server returned non-json response: %s", resp.text[:500])
        return {"ok": False, "error": "Invalid JSON from LLM server"}

    if isinstance(result, dict) and ("error" in result or "detail" in result):
        msg = result.get("error") or result.get("detail") or "LLM server reported an error"
        return {"ok": False, "error": f"LLM server: {msg}"}

    is_valid, validation_error = _minimal_validate_challenge(result)
    
    if not is_valid:
        logger.error("LLM response failed validation: %s -- response: %s", validation_error, str(result)[:500])
        return {"ok": False, "error": f"Invalid LLM response: {validation_error}"}

    return {"ok": True, "result": result}


@router.post("/prompt", status_code=200)
def get_llm_response(payload: GeneratePlan) -> dict:
    token = payload.token
    user_goal = payload.plan # Rename variable for clarity (this is the 'goal')
    print("user_goal: ", user_goal)
    # 1. Verify Session
    valid_token, user_id = session.verify_session(token)
    if not valid_token:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    # 2. Get User Data (Goal, Level, AND History)
    results = db.find_one(
        table_name="users", 
        filters={"user_id": user_id}, 
        projection={"_id": False, "height": True, "weight" : True, "sex" : True, "gathered_info" : True, "repsonses" : True, "prompts" : True}
    )
    last_prompt = results["prompts"][-1]
    last_response = results["repsonses"][-1]
    history = {"last_prompt" : last_prompt, "last_response" : last_response}
    # to do gathered dict
    if results is None:
        raise HTTPException(status_code = 402, detail = "Invalid user projection")
    user_info = {"height" : results["height"], 
                 "weight" : results["weight"], 
                 "sex" : results["sex"], 
                 "infos" : results["gathered_info"]}
    # 3. Prepare Payload for LLM
    # We send raw data; the LLM server constructs the System/User prompts
    llm_payload = {
        "goal": user_goal,
        "level": user_info.get("level", "Beginner"), # Default to beginner if missing
        "history": history, # Only send last 3 to save tokens/context
        "user_info": user_info 
    }
    print("The Payload")
    print("THE PAYLOAD: ", llm_payload)
    # 4. Call the AI Service
    # Expected response: {"ok": True, "result": {"challenges_count": 1, "challenges_list": [...]}}
    llm_resp = send_json_to_llm_server(llm_payload)

    if not llm_resp.get("ok"):
        err_msg = llm_resp.get("error", "Unknown error from LLM service")
        logger.error("LLM service error for user %s: %s", user_id, err_msg)
        raise HTTPException(status_code=502, detail=f"LLM service error: {err_msg}")
    
    generated_data = llm_resp.get("result") or llm_resp.get("challenge") 

    # 5. Update Database
    # We store the whole structure now
    plan_id = db.find_one_and_update("users", 
                                     keys_dict = {"user_id" : user_id}, 
                                     return_policy = ReturnDocument.BEFORE, 
                                     values_dict = {"$inc" : {"plan_id" : 1}}, 
                                     projection = {"_id" : False, "plan_id" : True})
    task_id = 0
    plan_struct = {"plan_id" : plan_id, 
                   "user_id" : user_id, 
                   "n_tasks" : generated_data["challenges_count"], 
                   "reponses": [generated_data],
                   "prompts": [user_goal],
                   "deleted": False,
                   "n_tasks_done": 0,
                   "created_at": timing.now_iso(),
                   "expected_complete": None,
                   }
    db.insert("plans", {})
    # 6. Return to Frontend
    return {"ok": True, "data": generated_data}