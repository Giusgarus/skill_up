import json
import logging
from pathlib import Path
from statistics import mean
from fastapi import APIRouter, HTTPException
import backend.db.database as db
import backend.utils.session as session
import backend.utils.timing as timing
from pydantic import BaseModel
from typing import Annotated, Set, Any, Dict, Optional
from pymongo import ReturnDocument, ASCENDING, DESCENDING
import backend.utils.llm_interaction as llm
import backend.utils.data_handler as dh

logger = logging.getLogger(__name__)


# ==============================
#         Load Variables
# ==============================
CONFIG_PATH = Path(__file__).resolve().parents[2] / "utils" / "env.json"
with CONFIG_PATH.open("r", encoding="utf-8") as f:
    _cfg: Dict[str, Any] = json.load(f)

CHALLENGES_MIN_HEAP_K_LEADER = int(_cfg.get("CHALLENGES_MIN_HEAP_K_LEADER", 10))
CHALLENGES_DIFFICULTY_MAP = _cfg.get(
    "CHALLENGES_DIFFICULTY_MAP", {"easy": 1, "medium": 3, "hard": 5}
)


# ==============================
#        Payload Classes
# =================s=============
class User(BaseModel):
    token: str

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



# ==============================================
# ================== ROUTES ====================
# ==============================================

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
    
    # 1. Update task
    task = db.find_one_and_update(
        table_name = "tasks",
        keys_dict = {"task_id" : task_id, "user_id" : user_id, "plan_id" : plan_id}, 
        values_dict = {"$set": {"completed_at": timing.now_iso()}}, 
        projection = {"_id" : False, "score" : True}, 
        return_policy = ReturnDocument.AFTER
    )
    if not task:
        raise HTTPException(status_code = 404, detail = "Task not found")

    # 2. Update plans
    plan = db.find_one_and_update(
        table_name="plans",
        keys_dict={"user_id": user_id, "plan_id": plan_id},
        values_dict=[
            {
                "$set": {
                    "n_tasks_done": {"$add": ["$n_tasks_done", 1]},
                    "completed_at": {
                        "$cond": [ # sintax --> "$cond": [condition, true_case, false_case]
                            {
                                "$and": [
                                    {
                                        "$eq": [
                                            {"$add": ["$n_tasks_done", 1]}, # n_tasks_done+1 because is incremented now
                                            "$n_tasks",
                                        ]
                                    },
                                    {"$eq": ["$completed_at", None]},
                                ]
                            },                  # condition --> (n_tasks_done + 1 == n_tasks) AND (completed_at is None)
                            "$$NOW",            # true_case --> server time
                            "$completed_at",    # false_case --> current value
                        ]
                    },
                }
            }
        ],
        projection={"_id": False, "completed_at": True},
        return_policy=ReturnDocument.AFTER
    )
    if not plan:
        raise HTTPException(status_code = 405, detail = "Plan not found")
    
    # 3. Update users
    if plan["completed_at"] is not None:
        pull_active_plan = {"$pull": {"active_plans": plan_id}}
    else:
        pull_active_plan = {}
    user = db.find_one_and_update(
        table_name = "users",
        keys_dict = {"user_id": user_id},
        values_dict = {
            "$inc": {"n_tasks_done": 1, "score": task["score"]},
            **pull_active_plan
        },
        projection = {"_id": False, "username": True, "score": True}, 
        return_policy = ReturnDocument.AFTER
    )
    if not user:
        raise HTTPException(status_code = 406, detail = "User not found after update")
    if user["score"] is None or not user["username"]:
        raise HTTPException(status_code = 407, detail = "Invalid projection after updating user")
    
    # 4. Update medals
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
        
    # 5. Update leaderboard
    db.update_one(
        table_name = "leaderboard",
        keys_dict = {"_id": "topK"},
        values_dict = {
            "$pull": {"items": {"username": user["username"]}},
            "$push": {
                "items": {
                    "$each": [{"username": user["username"], "score": user["score"]}],
                    "$sort": {"score": -1, "username": 1},
                    "$slice": CHALLENGES_MIN_HEAP_K_LEADER
                }
            }
        }
    )
    
    return {"status" : True, "score": user["score"]}


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
    if not llm_resp.get("status"):
        err_msg = llm_resp.get("error", "Unknown error from LLM service")
        logger.error(f"LLM service error for user {user_id}: {err_msg}")
        raise HTTPException(status_code=502, detail=f"LLM service error: {err_msg}")
    tasks_dict = dict(llm_resp["result"]["tasks"])
    
    # 3. Update users
    user = db.find_one(
        table_name="users", 
        filters={"user_id" : user_id}, 
        projection = {"_id" : False, "n_plans" : True}
    )
    if not user or "n_plans" not in user:
        raise HTTPException(status_code = 503, detail = "Invalid User ID in projection while creating plan")
    plan_id = user["n_plans"]
    res = db.update_one(
        table_name="users", 
        keys_dict = {"user_id" : user_id}, 
        values_dict = {
            "$inc" : {"n_plans" : 1},
            "$push": {"active_plans": plan_id}
        },
    )
    if res.matched_count == 0:
        raise HTTPException(status_code = 504, detail = "User not found while creating plan")

    # 4. Create plan
    difficulty_values: list[int] = [CHALLENGES_DIFFICULTY_MAP.get(str(task["difficulty"]).lower(), 1) for _, task in tasks_dict.items()]
    res = db.insert(
        table_name="plans",
        record={
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
    )
    if not res:
        raise HTTPException(status_code = 505, detail = "Database error while creating plan")

    # 5. Create tasks
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

    # 6. Prepare the return
    if "_id" in tasks_dict:
        del tasks_dict["_id"] # remove _id field if present

    return {
        "status": True,
        "plan_id": plan_id,
        "prompt": llm_resp["result"].get("prompt"),
        "response": llm_resp["result"].get("response"),
        "tasks": tasks_dict
    }


# ==========================
#        plan/delete
# ==========================
@router.post("/plan/delete", status_code = 200)
def delete_plan(payload: Plan) -> dict:
    plan_id = payload.plan_id
    ok, user_id = session.verify_session(payload.token)
    if not ok or not user_id:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    res = db.update_one(
        table_name="plans",
        keys_dict={"user_id" : user_id, "plan_id" : plan_id},
        values_dict = {"$set" : {"deleted" : True}, "$pull": {"active_plans": plan_id}}
    )
    if res.matched_count == 0:
        raise HTTPException(status_code = 402, detail = "Invalid Plan in Tables")
    return {"status" : True}


# ==========================
#       plan/active
# ==========================
@router.post("/plan/active", status_code=200)
def get_active_plan(payload: User) -> dict:
    ok, user_id = session.verify_session(payload.token)

    if not ok or not user_id:
        raise HTTPException(status_code=401, detail="Invalid or missing token")
    
    # 1. Get the active plans
    user = db.find_one(
        table_name="users",
        filters={"user_id": user_id},
        projection={"_id": False, "active_plans": True}
    )
    if not user:
        raise HTTPException(status_code=404, detail="No active plan found")
    
    # 2. Get the plans and their tasks
    all_plans = []
    for plan_id in user.get("active_plans", []):
        # get the plan
        plan = db.find_one(
            table_name="plans",
            filters={"user_id": user_id, "plan_id": plan_id},
            projection={
                "_id": False,
                "plan_id": True,
                "created_at": True,
                "expected_complete": True,
                "n_tasks": True,
                "n_tasks_done": True,
                "n_replans": True,
                "deleted": True,
                "tasks": True
            },
        )
        if not plan:
            logger.warning(f"Active plan '{plan_id}' for user '{user_id}' not found in plans collection")
            all_plans.append({"plan_id": plan_id, "error": "Plan not found"})
            continue
        # get tasks of the plan
        plan["tasks_all_info"] = []
        tasks = db.find_one(
            table_name="tasks",
            filters={"user_id": user_id, "plan_id": plan_id},
            projection={
                "_id": False,
                "task_id": True,
                "title": True,
                "description": True,
                "difficulty": True,
                "score": True,
                "deadline_date": True,
                "completed_at": True,
                "deleted": True,
            }
        )
        if not tasks:
            logger.warning(f"Failed to fetch tasks for plan '{plan_id}' of user '{user_id}'")
            continue
        plan["tasks_all_info"].append(tasks)
        # update plans
        all_plans.append(plan)

    return {"status": True, "plans": all_plans}


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
    if not llm_resp.get("status"):
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
