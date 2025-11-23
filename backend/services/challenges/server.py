import json
import logging
from pathlib import Path
from statistics import mean
from fastapi import APIRouter, HTTPException
import backend.db.database as db
import backend.utils.session as session
import backend.utils.timing as timing
from pydantic import BaseModel, StringConstraints
from typing import Annotated, Set, Any, Dict, Optional
from pymongo.errors import PyMongoError
from pymongo import ReturnDocument, ASCENDING, DESCENDING
import backend.utils.llm_interaction as llm
import backend.utils.data_handler as dh

logger = logging.getLogger(__name__)


# ==============================
#         Load Variables
# ==============================
# backend/utils/config.py


CONFIG_PATH = Path(__file__).resolve().parents[2] / "utils" / "env.json"

with CONFIG_PATH.open("r", encoding="utf-8") as f:
    _cfg: Dict[str, Any] = json.load(f)

# Registrazione / onboarding
REGISTER_QUESTIONS = _cfg.get("REGISTER_QUESTIONS", [])
REGISTER_INTERESTS_LABELS = _cfg.get("REGISTER_INTERESTS_LABELS", [])

# LLM
LLM_SERVER_URL = _cfg.get("LLM_SERVER_URL", "http://localhost:8001")
LLM_SERVICE_TOKEN = _cfg.get("LLM_SERVICE_TOKEN")
LLM_TIMEOUT = int(_cfg.get("LLM_TIMEOUT", 10))
LLM_MAX_RETRIES = int(_cfg.get("LLM_MAX_RETRIES", 2))

# Challenges
CHALLENGES_MIN_HEAP_K_LEADER = int(_cfg.get("CHALLENGES_MIN_HEAP_K_LEADER", 10))
CHALLENGES_ALLOWED_DATA_FIELDS: Set[str] = set(
    _cfg.get(
        "CHALLENGES_ALLOWED_DATA_FIELDS",
        ["score", "name", "surname", "height", "weight", "sex", "profile_pic"],
    )
)
CHALLENGES_MIN_LEN_ADF = int(_cfg.get("CHALLENGES_MIN_LEN_ADF", 1))
CHALLENGES_MAX_LEN_ADF = int(_cfg.get("CHALLENGES_MAX_LEN_ADF", 200000))
CHALLENGES_DIFFICULTY_MAP = _cfg.get(
    "CHALLENGES_DIFFICULTY_MAP", {"easy": 1, "medium": 3, "hard": 5}
)
# ==============================
#        Payload Classes
# =================s=============
RecordStr = Annotated[
    str,
    StringConstraints(
        strip_whitespace = True,
        min_length = CHALLENGES_MIN_LEN_ADF,
        max_length = CHALLENGES_MAX_LEN_ADF,
        pattern = r"^[\x20-\x7E]+$",
    )
]

class User(BaseModel):
    token: str

class UserBody(User):
    attribute: str
    record: RecordStr

class Goal(User):
    goal: str

class Plan(User):
    plan_id: int

class Task(Plan):
    task_id: int
    medal_taken: Optional[str] = "None"

class Replan(Plan):
    new_goal: str


# ===============================
#        Fast API Router
# ===============================
router = APIRouter(prefix="/services/challenges", tags=["challenges"])


def _get_active_plan_doc(user_id: str) -> dict | None:
    """Return the latest non-deleted plan for the user."""
    try:
        collection = db.connect_to_db()["plans"]
        return collection.find_one(
            {"user_id": user_id, "deleted": False},
            sort=[("created_at", DESCENDING), ("plan_id", DESCENDING)],
            projection={"_id": False},
        )
    except Exception as exc:  # noqa: BLE001
        logger.error("Unable to fetch active plan for %s: %s", user_id, exc)
        return None



# ==============================================
# ================== ROUTES ====================
# ==============================================

# ==========================
#            set
# ==========================
@router.post("/set", status_code = 200)
def update_user(payload: UserBody):
    valid_token, user_id = session.verify_session(payload.token)
    if not valid_token:
        raise HTTPException(status_code = 400, detail = "Invalid or missing token")
    attribute = payload.attribute.strip()
    if attribute not in CHALLENGES_ALLOWED_DATA_FIELDS:
        raise HTTPException(status_code = 401, detail = "Unsupported attribute")
    # Special-case username to avoid collisions
    if attribute == "username":
        existing = db.find_one(
            table_name="users",
            filters={"username": payload.record},
            projection={"_id": False, "user_id": True},
        )
        if existing and existing.get("user_id") != user_id:
            raise HTTPException(status_code=409, detail="Username already in use")
    try:
        up_status = db.update_one(
            table_name="users",
            keys_dict={"user_id" : user_id},
            values_dict={"$set": {payload.attribute: payload.record}}
        )
    except PyMongoError:
        raise HTTPException(status_code = 402, detail = "Database error")
    if up_status.matched_count == 0:
            raise HTTPException(status_code = 403, detail = "User not found")
    return {"status": True, "attribute": attribute, "new_record": payload.record}

# ==========================
#         task_done
# ==========================
@router.post("/task_done", status_code = 200)
def task_done(payload: Task) -> dict:
    ok, user_id = session.verify_session(payload.token)
    plan_id = payload.plan_id
    task_id = payload.task_id

    if not ok or not user_id:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    if plan_id is None:
        raise HTTPException(status_code = 402, detail = "Invalid Plan ID")
    if task_id is None:
        raise HTTPException(status_code = 403, detail = "Invalid Task ID")
    
    proj_task = db.find_one_and_update(
        table_name = "tasks",
        keys_dict = {"task_id" : task_id, "user_id" : user_id, "plan_id" : plan_id}, 
        values_dict = {"$set": {"completed_at": timing.now_iso()}}, 
        projection = {"_id" : False, "score" : True}, 
        return_policy = ReturnDocument.AFTER
    )

    # 2. Update users
    score = proj_task["score"] if proj_task else None
    if score is None:
        raise HTTPException(status_code = 404, detail = "Invalid score in Task ID")
    
    res = db.update_one(
        table_name="plans",
        keys_dict={"user_id": user_id, "plan_id": plan_id},
        values_dict=[
            {
                "$set": {
                    "n_tasks_done": {"$add": ["$n_tasks_done", 1]},
                    "completed_at": {
                        "$cond": [
                            {
                                "$and": [
                                    {
                                        "$eq": [
                                            {"$add": ["$n_tasks_done", 1]},  # new value
                                            "$n_tasks",
                                        ]
                                    },
                                    # only set once, when previously null
                                    {"$eq": ["$completed_at", None]},
                                ]
                            },
                            "$$NOW",          # server time
                            "$completed_at",  # keep existing value
                        ]
                    },
                }
            }
        ],
    )
    if res.matched_count == 0:
        raise HTTPException(status_code = 405, detail = "Plan not found")

    proj_user_data = db.find_one_and_update(
        table_name = "users",
        keys_dict = {"user_id": user_id},
        values_dict = {"$inc": {"n_tasks_done": 1, "score": score}},
        projection = {"_id": False, "username": True, "score": True}, 
        return_policy = ReturnDocument.AFTER
    )

    if not proj_user_data:
        raise HTTPException(status_code = 406, detail = "User not found after update")
    
    new_score = proj_user_data["score"]
    username = proj_user_data["username"]

    if new_score is None or not username:
        raise HTTPException(status_code = 407, detail = "Invalid projection after updating user")

    
    # 3. Update medals
    if payload.medal_taken and payload.medal_taken != "None":
        day_str = timing.now().date().isoformat()
        res = db.update_one(
            table_name = "medals",
            keys_dict = {"user_id": user_id, "timestamp": day_str},
            values_dict = {
                "$push": {
                    "medal": {
                        "grade": payload.medal_taken,
                        "task_id": task_id
                    }
                }
            },
            upsert = True
        )
        if not (res.matched_count or res.upserted_id):
            raise HTTPException(status_code = 408, detail = "Invalid medal passed")
        
    # 4. Update leaderboard
    db.update_one(
        table_name = "leaderboard",
        keys_dict = {"_id": "topK"},
        values_dict = {
            "$pull": {"items": {"username": username}},
            "$push": {
                "items": {
                    "$each": [{"username": username, "score": new_score}],
                    "$sort": {"score": -1, "username": 1},
                    "$slice": CHALLENGES_MIN_HEAP_K_LEADER
                }
            }
        }
    )
    
    return {"status" : True, "score": new_score}


# ==========================
#          prompt
# ==========================
@router.post("/prompt", status_code=200)
def get_llm_response(payload: Goal) -> dict:
    token = payload.token
    user_goal = payload.goal

    # 1. Verify Session
    valid_token, user_id = session.verify_session(token)
    if not valid_token:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    
    # 2. Communication with LLM server --> expected response: {"ok": True, "result": {"n_tasks": ..., "tasks": ...}}
    llm_payload = {
        "goal": user_goal,
        "level": "0", # Default to beginner (0=beginner, 1=intermediate, 2=advanced)
        "history": {}, # empty because we haven't previous prompts/responses for this plan (because has to be created now)
        "user_info": dh.get_user_info(user_id)
    }
    llm_resp = llm.get_llm_response(llm_payload)
    if not llm_resp.get("ok"):
        err_msg = llm_resp.get("error", "Unknown error from LLM service")
        logger.error(f"LLM service error for user {user_id}: {err_msg}")
        raise HTTPException(status_code=502, detail=f"LLM service error: {err_msg}")

    tasks_dict = dict(llm_resp["result"]["tasks"])
    
    # 3. Update Database --> we store the whole structure now
    proj = db.find_one_and_update(
        table_name="users", 
        keys_dict = {"user_id" : user_id}, 
        values_dict = {"$inc" : {"n_plans" : 1}}, 
        projection = {"_id" : False, "n_plans" : True},
        return_policy = ReturnDocument.AFTER
    )
    if not proj or "n_plans" not in proj:
        raise HTTPException(status_code = 503, detail = "Invalid User ID in projection while creating plan")
    plan_id = proj["n_plans"]
    difficulty_values = [CHALLENGES_DIFFICULTY_MAP.get(str(task["difficulty"]).lower(), 1) for _, task in tasks_dict.items()]
    plan = {
        "plan_id" : plan_id,
        "user_id" : user_id,
        "n_tasks" : len(tasks_dict),
        "responses": [],
        "prompts": [],
        "deleted": False,
        "difficulty": round(mean(difficulty_values)) if difficulty_values else 1,
        "n_tasks_done": 0,
        "created_at": timing.now_iso(),
        "expected_complete": timing.get_last_date(list(tasks_dict.keys())),
        "n_replans": 0,
        "tasks": [{date: [task] for date, task in tasks_dict.items()}],
    }
    db.insert("plans", plan)
    tasks: list[dict[str, Any]] = []
    for i, (date, task) in enumerate(tasks_dict.items()):
        timing.from_iso_to_datetime(date)
        diff_key = str(task["difficulty"]).lower()
        difficulty = CHALLENGES_DIFFICULTY_MAP.get(diff_key, 1)
        score = difficulty * 10
        tasks.append(
            {
                "task_id": i,
                "plan_id": plan_id,
                "user_id": user_id,
                "title": task["title"],
                "description": task["description"],
                "difficulty": difficulty,
                "score": score,
                "deadline_date": date,
                "completed_at": None,
                "deleted": False,
            }
        )
    db.insert_many("tasks", tasks)
    safe_tasks = [{k: v for k, v in task.items() if k != "_id"} for task in tasks]

    return {
        "status": True,
        "plan_id": plan_id,
        "tasks": safe_tasks,
        "data": llm_resp["result"],
        "prompt": llm_resp["result"].get("prompt"),
    }


# ==========================
#       prompt/delete
# ==========================
@router.post("/plan/delete", status_code = 200)
def delete_plan(payload: Plan) -> dict:
    plan_id = payload.plan_id
    ok, user_id = session.verify_session(payload.token)
    if not ok or not user_id:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    res = db.update_one("plans", keys_dict = {"user_id" : user_id, "plan_id" : plan_id}, values_dict = {"$set" : {"deleted" : True}})
    if res.matched_count == 0:
        raise HTTPException(status_code = 402, detail = "Invalid Plan in Tables")
    return {"status" : True}


@router.post("/plan/active", status_code=200)
def get_active_plan(payload: User) -> dict:
    ok, user_id = session.verify_session(payload.token)
    if not ok or not user_id:
        raise HTTPException(status_code=401, detail="Invalid or missing token")
    plan_doc = _get_active_plan_doc(user_id)
    if plan_doc is None:
        raise HTTPException(status_code=404, detail="No active plan found")
    try:
        tasks_cursor = (
            db.connect_to_db()["tasks"]
            .find(
                {"user_id": user_id, "plan_id": plan_doc["plan_id"], "deleted": False},
                {"_id": False},
            )
            .sort([("task_id", ASCENDING)])
        )
        tasks = list(tasks_cursor)
    except Exception as exc:  # noqa: BLE001
        logger.error("Failed to fetch tasks for plan %s: %s", plan_doc["plan_id"], exc)
        raise HTTPException(status_code=500, detail="Unable to fetch plan tasks")
    plan_payload = {
        "plan_id": plan_doc.get("plan_id"),
        "created_at": plan_doc.get("created_at"),
        "expected_complete": plan_doc.get("expected_complete"),
        "n_tasks": plan_doc.get("n_tasks"),
        "n_tasks_done": plan_doc.get("n_tasks_done", 0),
        "n_replans": plan_doc.get("n_replans", 0),
        "deleted": plan_doc.get("deleted", False),
    }
    return {"status": True, "plan": plan_payload, "tasks": tasks}


# ==========================
#          replan
# ==========================
@router.post("/prompt/replan", status_code = 200)
def replan(payload: Replan):
    plan_id = payload.plan_id
    new_goal = payload.new_goal
    ok, user_id = session.verify_session(payload.token)
    if not ok or not user_id:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")

    # 1. Retrieve the plan from the DB
    plan = db.find_one(
        table_name="plans",
        filters={"user_id": user_id, "plan_id": plan_id},
        projection = {"_id" : False, "prompts": True, "responses" : True, "n_tasks": True}
    )
    if not plan_id or plan is None:
        raise HTTPException(status_code = 402, detail = "Invalid Plan ID")
    
    # 2. Communication with the LLM server
    llm_payload = {
        "goal": new_goal,
        "level": "0", # Default to beginner (0=beginner, 1=intermediate, 2=advanced)
        "history": {"last_prompt": plan["prompts"][-1], "last_response": plan["responses"][-1]},
        "user_info": dh.get_user_info(user_id)
    }
    llm_resp = llm.get_llm_response(llm_payload)
    if not llm_resp.get("ok"):
        err_msg = llm_resp.get("error", "Unknown error from LLM service")
        logger.error(f"LLM service error for user {user_id}: {err_msg}")
        raise HTTPException(status_code=502, detail=f"LLM service error: {err_msg}")
    
    new_tasks_dict = dict(llm_resp["result"]["tasks"])
    n_tasks = plan["n_tasks"]

    # 3. Update the tasks
    db.update_many_filtered(
        table_name="tasks",
        filter={"plan_id": plan_id, "user_id": user_id},
        update={"$set": {"deleted": True}},
    )
        # 4. Insert new tasks continuing IDs
    tasks = []
    for i, (date, task) in enumerate(new_tasks_dict.items()):
        timing.from_iso_to_datetime(date)
        diff_key = str(task["difficulty"]).lower()
        difficulty = CHALLENGES_DIFFICULTY_MAP.get(diff_key, 1)
        score = difficulty * 10
        tasks.append(
            {
                "task_id": n_tasks + i,  # new task_id continues from previous plan tasks
                "plan_id": plan_id,
                "user_id": user_id,
                "title": task["title"],
                "description": task["description"],
                "difficulty": difficulty,
                "score": score,
                "deadline_date": date,
                "completed_at": None,
                "deleted": False,
            }
        )
    db.insert_many("tasks", tasks)
    safe_tasks = [{k: v for k, v in task.items() if k != "_id"} for task in tasks]
    # 5. Update the plan
    db.find_one_and_update(
        table_name="plans",
        keys_dict={"user_id": user_id, "plan_id": plan_id},
        values_dict={
            "$inc": {"n_replans": 1, "n_tasks": len(new_tasks_dict)},
            "$push": {
                "prompts": llm_resp["result"]["prompt"],
                "responses": llm_resp["result"]["response"],
                "tasks": {date: [task] for date, task in new_tasks_dict.items()},
            },
        },
        return_policy=ReturnDocument.AFTER,
    )
    return {
        "status": True,
        "plan_id": plan_id,
        "tasks": safe_tasks,
        "data": llm_resp["result"],
        "prompt": llm_resp["result"].get("prompt"),
    }
