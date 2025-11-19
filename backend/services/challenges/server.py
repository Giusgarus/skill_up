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

# @router.post("/prompt", status_code = 200)
# def get_llm_response(payload: GeneratePlan) -> dict:
#     token = payload.token
#     prompt = payload.plan
#     valid_token, user_id = session.verify_session(token)
#     if not valid_token:
#         raise HTTPException(status_code = 401, detail = "Invalid or missing token")
#     results = db.find_one(table_name = "users", filters = {"user_id": user_id}, projection = {"_id": False, "data": True})
#     if results == None:
#         raise HTTPException(status_code = 402, detail = "Invalid user")
#     user_info = results["data"] if results else None
#     if not user_info:
#         user_info = {}
#     # Qui dovresti implementare la chiamata al server di mos --> HTTP/JSON request
#     llm_response = send_json_to_llm_server({
#         "prompt": prompt,
#         "user_info": user_info
#     })
#     # Controlla risposta e aggiorna tutti i campi necessari 
#     # ...
#     # Create Medals with the empty timestamps
#     return {}


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
       "challenges_count": int,
       "challenges_list": [ ... ]
    }
    """
    if not isinstance(resp, dict):
        return False, "Response is not a JSON object"

    # 1. Validate Top Level Keys
    if "challenges_list" not in resp or not isinstance(resp["challenges_list"], list):
        return False, "Missing or invalid 'challenges_list'"
    
    if "challenges_count" not in resp or not isinstance(resp["challenges_count"], int):
        return False, "Missing or invalid 'challenges_count'"

    if len(resp["challenges_list"]) == 0:
        return False, "Challenge list is empty"

    # 2. Validate Individual Challenge Objects
    required_item_keys = ["challenge_title", "challenge_description", "duration_minutes", "difficulty"]
    
    for index, item in enumerate(resp["challenges_list"]):
        # Check Keys
        for k in required_item_keys:
            if k not in item:
                return False, f"Challenge #{index+1} missing key: {k}"
        
        # Check Types
        if not isinstance(item["challenge_title"], str) or not isinstance(item["challenge_description"], str):
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
        raise HTTPException(status_code=401, detail="Invalid or missing token")

    # 2. Get User Data (Goal, Level, AND History)
    results = db.find_one(
        table_name="users", 
        filters={"user_id": user_id}, 
        projection={"_id": False, "data": True}
    )
    
    if results is None:
        raise HTTPException(status_code=402, detail="Invalid user")

    user_info = results.get("data", {}) or {}
    
    # Extract History for Progression Context (Crucial for Gamification)
    # Assuming history is stored in user_info under 'history' or 'past_challenges'
    user_history = user_info.get("history", []) 

    # 3. Prepare Payload for LLM Server
    # We send raw data; the LLM server constructs the System/User prompts
    llm_payload = {
        "goal": user_goal,
        "level": user_info.get("level", "Beginner"), # Default to beginner if missing
        "history": user_history[-3:], # Only send last 3 to save tokens/context
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

    # 5. Extract and Validate the AI Data
    # NOTE: Adjust key "result" below to match whatever key your send_json_to_llm_server returns
    generated_data = llm_resp.get("result") or llm_resp.get("challenge") 

    is_valid, err = _minimal_validate_challenge(generated_data)
    if not is_valid:
        logger.error(f"Validation failed for user {user_id}: {err}")
        # Fallback logic could go here (return hardcoded challenge)
        raise HTTPException(status_code=502, detail=f"AI generated invalid format: {err}")

    # 6. Update Database
    # We store the whole structure now
    try:
        update_doc = {
            "last_generated_data": {
                "challenges": generated_data["challenges_list"], # Store the list
                "meta": generated_data["challenges_count"],
                "original_goal": user_goal,
                "generated_at": int(time.time())
            }
        }
        
        db.update_one(
            table_name="users",
            filters={"user_id": user_id},
            update={"$set": update_doc}
        )
    except Exception as e:
        logger.exception("Failed to update DB for user %s: %s", user_id, e)

    # 7. Return to Frontend
    return {"ok": True, "data": generated_data}