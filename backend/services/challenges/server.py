import json
import logging
from pathlib import Path
from statistics import mean
from datetime import timedelta, date as date_cls
from fastapi import APIRouter, HTTPException
import backend.db.database as db
import backend.utils.session as session
import backend.utils.timing as timing
from pydantic import BaseModel
from typing import Annotated, List, Set, Any, Dict, Optional
from pymongo import ReturnDocument, ASCENDING, DESCENDING
import backend.utils.llm_interaction as llm
import backend.utils.data_handler as dh
from backend.services.gathering import server as gathering_server

logger = logging.getLogger(__name__)


# ==============================
#         Load Variables
# ==============================
CONFIG_PATH = Path(__file__).resolve().parents[2] / "utils" / "env.json"
with CONFIG_PATH.open("r", encoding="utf-8") as f:
    _cfg = json.load(f)

CHALLENGES_MIN_HEAP_K_LEADER = int(_cfg.get("CHALLENGES_MIN_HEAP_K_LEADER"))
CHALLENGES_DIFFICULTY_MAP = _cfg.get("CHALLENGES_DIFFICULTY_MAP")
HARD_TEMPLATES: Dict[str, List[Dict[str, Any]]] = {
    "hard1": [
        {"title": "Morning jog", "description": "Run for 20 minutes at easy pace", "difficulty": "easy", "offset": 0},
        {"title": "Core blast", "description": "3x15 crunches + 2x30s plank", "difficulty": "medium", "offset": 1},
        {"title": "Stretch", "description": "10 minutes full body stretch", "difficulty": "easy", "offset": 2},
    ],
    "hard2": [
        {"title": "Focus sprint", "description": "45 minutes deep work, no phone", "difficulty": "medium", "offset": 0},
        {"title": "Inbox zero", "description": "Clear email + messages backlog", "difficulty": "easy", "offset": 1},
        {"title": "Reflection", "description": "Write 5 bullet points about today", "difficulty": "easy", "offset": 1},
    ],
    "hard3": [
        {"title": "Strength circuit", "description": "3x12 squats, 3x10 pushups, 3x12 lunges", "difficulty": "hard", "offset": 0},
        {"title": "Walk", "description": "30 minute brisk walk", "difficulty": "easy", "offset": 2},
    ],
    "hard4": [
        {"title": "Mindfulness", "description": "15 minutes guided meditation", "difficulty": "easy", "offset": 0},
        {"title": "Learning", "description": "Study 25 minutes a new topic", "difficulty": "medium", "offset": 1},
        {"title": "Review", "description": "Summarize what you learned", "difficulty": "easy", "offset": 1},
    ],
}


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

class Report(Task):
    report: str

class Replan(Plan):
    new_goal: str
    
class HardPlan(User):
    preset: str


# ===============================
#        Fast API Router
# ===============================
router = APIRouter(prefix="/services/challenges", tags=["challenges"])

def _insert_plan_for_user(
    user_id: str,
    tasks_dict: Dict[str, Dict[str, Any]],
    prompt_text: str | None = None,
    response_payload: Any = None,
) -> Dict[str, Any]:
    """Create plan and tasks for a user given a tasks dict (date -> task)."""
    # 3. Update users (increment plan counter and track active plan)
    user_doc = db.find_one(
        table_name="users",
        filters={"user_id": user_id},
        projection={"_id": False, "n_plans": True},
    )
    if user_doc is None or "n_plans" not in user_doc:
        raise HTTPException(
            status_code=503,
            detail="Invalid user_id or n_plans missing while creating plan",
        )

    plan_id = int(user_doc.get("n_plans", 0) or 0) + 1 # Why +1? if we start from 0 is without +1
    update_user_res = db.update_one(
        table_name="users",
        keys_dict={"user_id": user_id},
        values_dict={
            "$set": {"n_plans": plan_id},
            "$addToSet": {"active_plans": plan_id},
        },
    )
    if update_user_res.matched_count == 0:
        raise HTTPException(
            status_code=503, detail="Invalid user_id while creating plan"
        )

    difficulty_values: List[int] = [
        CHALLENGES_DIFFICULTY_MAP.get(str(task["difficulty"]).lower(), 1)  # default difficulty
        for _, task in tasks_dict.items()
    ]

    res = db.insert(
        table_name="plans",
        record={
            "plan_id": plan_id,
            "user_id": user_id,
            "n_tasks": len(tasks_dict),  # current tasks count
            "n_tasks_done": 0,
            "responses": [response_payload],
            "prompts": [prompt_text],
            "deleted": False,
            "difficulty": round(mean(difficulty_values)) if difficulty_values else 1,
            "created_at": timing.now_iso(),
            "expected_complete": timing.get_last_date(list(tasks_dict.keys())),
            "n_replans": 0,
            "tasks": [{date: [task] for date, task in tasks_dict.items()}],
            "next_task_id": len(tasks_dict), # keep a running task id counter for uniqueness across replans
            "completed_at": None,
        },
    )
    if not res:
        raise HTTPException(
            status_code=505, detail="Database error while creating plan"
        )

    # Create tasks
    tasks: List[Dict[str, Any]] = []
    for i, (date, task) in enumerate(tasks_dict.items()):
        timing.from_iso_to_datetime(date) # validate the date
        difficulty = CHALLENGES_DIFFICULTY_MAP.get(str(task["difficulty"]).lower(), 1)
        tasks.append({
            "task_id": i,
            "plan_id": plan_id,
            "user_id": user_id,
            "title": task["title"],
            "description": task["description"],
            "difficulty": difficulty,
            "score": difficulty * 10,
            "deadline_date": date,
            "completed_at": None,
            "deleted": False
        })
    db.insert_many("tasks", tasks)

    safe_tasks = [{k: v for k, v in task.items() if k != "_id"} for task in tasks]

    return {
        "status": True,
        "plan_id": plan_id,
        "prompt": prompt_text,
        "response": response_payload,
        "tasks": safe_tasks,
        "expected_complete": timing.get_last_date(list(tasks_dict.keys())),
        "created_at": timing.now_iso(),
    }

def _build_hard_tasks(template_key: str) -> Dict[str, Dict[str, Any]]:
    template = HARD_TEMPLATES.get(template_key.lower())
    if not template:
        raise HTTPException(status_code=404, detail="Unknown preset plan")
    today = timing.now().date()
    tasks: Dict[str, Dict[str, Any]] = {}
    for item in template:
        offset = int(item.get("offset", 0))
        day = today + timedelta(days=offset)
        tasks[day.isoformat()] = {
            "title": item.get("title", ""),
            "description": item.get("description", ""),
            "difficulty": item.get("difficulty", "easy"),
        }
    return tasks


# ==============================================
# ================== ROUTES ====================
# ==============================================

# ==========================
#         task_done
# ==========================
@router.post("/task_done", status_code=200)
async def task_done(payload: Task) -> dict:
    ok, user_id = session.verify_session(payload.token)
    plan_id = payload.plan_id
    task_id = payload.task_id

    if not ok or not user_id:
        raise HTTPException(status_code=401, detail="Invalid or missing token")
    if plan_id is None:
        raise HTTPException(status_code=402, detail="Invalid Plan ID")
    if task_id is None:
        raise HTTPException(status_code=403, detail="Invalid Task ID")

    # 1. Update task (only non-deleted tasks)
    task = db.find_one_and_update(
        table_name="tasks",
        keys_dict={
            "task_id": task_id,
            "user_id": user_id,
            "plan_id": plan_id,
            "deleted": False,
            "completed_at": None,
        },
        values_dict={"$set": {"completed_at": timing.now_iso()}},
        projection={"_id": False, "score": True},
        return_policy=ReturnDocument.AFTER,
    )
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")

    now = timing.now_iso()

    plan = db.find_one_and_update(
        table_name="plans",
        keys_dict={"user_id": user_id, "plan_id": plan_id},
        values_dict=[
            # 1) increment n_tasks_done (handle null / missing)
            {
                "$set": {
                    "n_tasks_done": {
                        "$add": [
                            {"$ifNull": ["$n_tasks_done", 0]},
                            1,
                        ]
                    }
                }
            },
            # 2) conditionally set completed_at
            {
                "$set": {
                    "completed_at": {
                        "$cond": [
                            {
                                "$and": [
                                    # only if not already completed
                                    {"$eq": ["$completed_at", None]},
                                    # only if there is at least 1 task
                                    {
                                        "$gt": [
                                            {"$ifNull": ["$n_tasks", 0]},
                                            0,
                                        ]
                                    },
                                    # and AFTER increment, we've hit or exceeded total tasks
                                    {
                                        "$gte": [
                                            "$n_tasks_done",  # this is the incremented value from stage 1
                                            {"$ifNull": ["$n_tasks", 0]},
                                        ]
                                    },
                                ]
                            },
                            now,              # set to this constant timestamp
                            "$completed_at",  # otherwise keep previous
                        ]
                    }
                }
            },
        ],
        projection={"_id": False, "completed_at": True},
        return_policy=ReturnDocument.AFTER,
    )

    if not plan:
        raise HTTPException(status_code=405, detail="Plan not found")

    # 3. Update user
    pull_active_plan: Dict[str, Any] = {}
    if plan["completed_at"] is not None:
        pull_active_plan = {"$pull": {"active_plans": plan_id}}

    user = db.find_one_and_update(
        table_name="users",
        keys_dict={"user_id": user_id},
        values_dict={
            "$inc": {"n_tasks_done": 1, "score": task["score"]},
            **pull_active_plan,
        },
        projection={"_id": False, "username": True, "score": True},
        return_policy=ReturnDocument.AFTER,
    )
    if not user:
        raise HTTPException(status_code=406, detail="User not found after update")
    if user["score"] is None or not user["username"]:
        raise HTTPException(
            status_code=407, detail="Invalid projection after updating user"
        )
    
    # 4. Update medals
    if payload.medal_taken != "None":
        day_str = timing.now().date().isoformat()
        res = db.update_one(
            table_name="medals",
            keys_dict={"user_id": user_id, "timestamp": day_str},
            values_dict={
                "$push": {
                    "medal": {"grade": payload.medal_taken, "task_id": task_id}
                }
            },
            upsert=True,
        )
        if not (res.matched_count or res.upserted_id):
            raise HTTPException(status_code=408, detail="Invalid medal passed")

    # 5. Update leaderboard (split pull/push to avoid Mongo path conflicts)
    try:
        db.update_one(
            table_name="leaderboard",
            keys_dict={"_id": "topK"},
            values_dict={"$pull": {"items": {"username": user["username"]}}},
        )
        db.update_one(
            table_name="leaderboard",
            keys_dict={"_id": "topK"},
            values_dict={
                "$push": {
                    "items": {
                        "$each": [
                            {"username": user["username"], "score": user["score"]}
                        ],
                        "$sort": {"score": -1, "username": 1},
                        "$slice": CHALLENGES_MIN_HEAP_K_LEADER,
                    }
                },
            },
        )
    except Exception as exc:
        logger.error("Failed to update leaderboard for user %s: %s", user["username"], exc)

    return {"status": True, "score": user["score"]}


# ==========================
#        task_undo
# ==========================
@router.post("/task_undo", status_code=200)
async def task_undo(payload: Task) -> dict:
    ok, user_id = session.verify_session(payload.token)
    plan_id = payload.plan_id
    task_id = payload.task_id

    if not ok or not user_id:
        raise HTTPException(status_code=401, detail="Invalid or missing token")
    if plan_id is None:
        raise HTTPException(status_code=402, detail="Invalid Plan ID")
    if task_id is None:
        raise HTTPException(status_code=403, detail="Invalid Task ID")

    # Ensure the task exists and is currently completed
    task_doc = db.find_one(
        table_name="tasks",
        filters={
            "task_id": task_id,
            "user_id": user_id,
            "plan_id": plan_id,
            "deleted": False,
        },
        projection={"_id": False, "score": True, "completed_at": True},
    )
    if not task_doc or task_doc.get("completed_at") is None:
        raise HTTPException(status_code=404, detail="Task not completed or not found")

    # 1. Mark task as not completed
    task = db.find_one_and_update(
        table_name="tasks",
        keys_dict={
            "task_id": task_id,
            "user_id": user_id,
            "plan_id": plan_id,
            "deleted": False,
            "completed_at": {"$ne": None},
        },
        values_dict={"$set": {"completed_at": None}},
        projection={"_id": False, "score": True},
        return_policy=ReturnDocument.AFTER,
    )
    if not task:
        raise HTTPException(status_code=404, detail="Task not completed or not found")

    # 2. Update plan counters and completion flag
    plan = db.find_one_and_update(
        table_name="plans",
        keys_dict={"user_id": user_id, "plan_id": plan_id},
        values_dict=[
            {
                "$set": {
                    "n_tasks_done": {
                        "$max": [
                            0,
                            {
                                "$subtract": [
                                    {"$ifNull": ["$n_tasks_done", 0]},
                                    1,
                                ]
                            },
                        ]
                    }
                }
            },
            {
                "$set": {"completed_at": None}
            }
        ],
        projection={"_id": False, "completed_at": True, "n_tasks_done": True},
        return_policy=ReturnDocument.AFTER,
    )
    if not plan:
        raise HTTPException(status_code=405, detail="Plan not found")

    # 3. Update user stats
    user = db.find_one_and_update(
        table_name="users",
        keys_dict={"user_id": user_id},
        values_dict={
            "$inc": {"n_tasks_done": -1, "score": -task_doc["score"]},
            "$addToSet": {"active_plans": plan_id}
        },
        projection={"_id": False, "username": True, "score": True},
        return_policy=ReturnDocument.AFTER,
    )
    if not user:
        raise HTTPException(status_code=406, detail="User not found after update")
    if user["score"] is None or not user["username"]:
        raise HTTPException(status_code=407, detail="Invalid projection after updating user")

    # 4. Remove medal entry for this task/day (best-effort)
    try:
        completion_day = (timing.from_iso_to_datetime(task_doc["completed_at"]).date().isoformat())
    except Exception:
        completion_day = timing.now().date().isoformat()

    try:
        db.update_one(
            table_name="medals",
            keys_dict={"user_id": user_id, "timestamp": completion_day},
            values_dict={"$pull": {"medal": {"task_id": task_id}}},
        )
    except Exception as exc:
        logger.error("Failed to remove medal for user %s: %s", user["username"], exc)

    # 5. Update leaderboard (split pull/push to avoid Mongo path conflicts)
    try:
        db.update_one(
            table_name="leaderboard",
            keys_dict={"_id": "topK"},
            values_dict={"$pull": {"items": {"username": user["username"]}}},
        )
        db.update_one(
            table_name="leaderboard",
            keys_dict={"_id": "topK"},
            values_dict={
                "$push": {
                    "items": {
                        "$each": [
                            {"username": user["username"], "score": user["score"]}
                        ],
                        "$sort": {"score": -1, "username": 1},
                        "$slice": CHALLENGES_MIN_HEAP_K_LEADER,
                    }
                },
            },
        )
    except Exception as exc:
        logger.error("Failed to update leaderboard for user %s: %s", user["username"], exc)

    return {"status": True, "score": user["score"]}


# ==========================
#          report
# ==========================
@router.post("/report", status_code=200)
def report(payload: Report) -> dict:
    plan_id = payload.plan_id
    task_id = payload.task_id
    report_str = payload.report
    ok, user_id = session.verify_session(payload.token)
    if not ok or not user_id:
        raise HTTPException(status_code=401, detail="Invalid or missing token")
    
    # 1. Set the report field in tasks collection
    res = db.update_one(
        table_name="tasks",
        keys_dict={
            "user_id": user_id,
            "plan_id": plan_id,
            "task_id": task_id,
        },
        values_dict={"$set": {"report": report_str}}
    )
    if res.matched_count == 0:
        raise HTTPException(status_code=503, detail="Invalid user_id while creating plan")

    return {"status": True}


# ==========================
#          prompt
# ==========================
@router.post("/prompt", status_code=200)
async def get_llm_response(payload: Goal) -> dict:
    token = payload.token
    user_goal = payload.goal

    # 1. Verify Session
    valid_token, user_id = session.verify_session(token)
    if not valid_token:
        raise HTTPException(status_code=401, detail="Invalid or missing token")

    # 2. Communicate with LLM server
    llm_payload = {
        "goal": user_goal,
        "level": "0",  # 0=beginner, 1=intermediate, 2=advanced
        "history": {},  # empty because this is a new plan
        "user_info": dh.get_user_info(user_id),
    }
    llm_resp = llm.get_llm_response(llm_payload)
    if not llm_resp.get("status"):
        err_msg = llm_resp.get("error", "Unknown error from LLM service")
        logger.error(f"LLM service error for user {user_id}: {err_msg}")
        raise HTTPException(status_code=502, detail=f"LLM service error: {err_msg}")

    tasks_dict: Dict[str, Dict[str, Any]] = dict(llm_resp["result"]["tasks"])
    tasks_dict.pop("_id", None)  # immediately

    # 3. Update users (increment plan counter and track active plan)
    user_doc = db.find_one(
        table_name="users",
        filters={"user_id": user_id},
        projection={"_id": False, "n_plans": True},
    )
    if user_doc is None or "n_plans" not in user_doc:
        raise HTTPException(
            status_code=503,
            detail="Invalid user_id or n_plans missing while creating plan",
        )

    plan_id = int(user_doc.get("n_plans", 0) or 0) + 1
    update_user_res = db.update_one(
        table_name="users",
        keys_dict={"user_id": user_id},
        values_dict={
            "$set": {"n_plans": plan_id},
            "$addToSet": {"active_plans": plan_id},
        },
    )
    if update_user_res.matched_count == 0:
        raise HTTPException(status_code=503, detail="Invalid user_id while creating plan")

    # 4. Create plan
    difficulty_values: List[int] = [
        CHALLENGES_DIFFICULTY_MAP.get(
            str(task["difficulty"]).lower(), 1  # default difficulty
        )
        for _, task in tasks_dict.items()
    ]
    res = db.insert(
        table_name="plans",
        record={
            "plan_id": plan_id,
            "user_id": user_id,
            "n_tasks": len(tasks_dict),  # current tasks count
            "n_tasks_done": 0,
            "responses": [llm_resp["result"].get("response")],
            "prompts": [llm_resp["result"].get("prompt")],
            "deleted": False,
            "difficulty": round(mean(difficulty_values)) if difficulty_values else 1,
            "created_at": timing.now_iso(),
            "expected_complete": timing.get_last_date(list(tasks_dict.keys())),
            "n_replans": 0,
            "tasks": [{date: [task] for date, task in tasks_dict.items()}],
            "next_task_id": len(tasks_dict), # keep a running task id counter for uniqueness across replans
            "completed_at": None,
        },
    )
    if not res:
        raise HTTPException(status_code=505, detail="Database error while creating plan")

    # 5. Create tasks
    tasks: List[Dict[str, Any]] = []
    for i, (date, task) in enumerate(tasks_dict.items()):
        # validate/parse date
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

    # 6. Prepare the return (strip any _id inside tasks_dict if present)
    if "_id" in tasks_dict:
        del tasks_dict["_id"]

    return {
        "status": True,
        "plan_id": plan_id,
        "prompt": llm_resp["result"].get("prompt"),
        "response": llm_resp["result"].get("response"),
        "tasks": tasks_dict,
    }


# ==========================
#       hardcoded plan
# ==========================
@router.post("/hard/{preset}", status_code=200)
async def create_hard_plan(preset: str, payload: User) -> dict:
    token = payload.token
    valid_token, user_id = session.verify_session(token)
    if not valid_token:
        raise HTTPException(status_code=401, detail="Invalid or missing token")
    tasks_dict = _build_hard_tasks(preset)
    prompt_text = f"Preset plan {preset}"
    return _insert_plan_for_user(
        user_id=user_id,
        tasks_dict=tasks_dict,
        prompt_text=prompt_text,
        response_payload={"preset": preset},
    )


# ==========================
#        plan/delete
# ==========================
@router.post("/plan/delete", status_code=200)
async def delete_plan(payload: Plan) -> dict:
    plan_id = payload.plan_id
    ok, user_id = session.verify_session(payload.token)
    if not ok or not user_id:
        raise HTTPException(status_code=401, detail="Invalid or missing token")

    # 1) mark plan as deleted
    res = db.update_one(
        table_name="plans",
        keys_dict={"user_id": user_id, "plan_id": plan_id},
        values_dict={"$set": {"deleted": True}},
    )
    if res.matched_count == 0:
        # io qui metterei 404, ma se vuoi tenere 402 è una scelta tua
        raise HTTPException(status_code=404, detail="Invalid plan")

    # 2) mark all *not completed yet* tasks for this plan as deleted
    #    (keep completed tasks as-is for history / stats)
    db.update_many_filtered(
        table_name="tasks",
        filter={
            "user_id": user_id,
            "plan_id": plan_id,
            "deleted": False,
            "completed_at": None,   # only unfinished tasks
        },
        update={"$set": {"deleted": True}},
    )

    # 3) remove from user.active_plans
    db.update_one(
        table_name="users",
        keys_dict={"user_id": user_id},
        values_dict={"$pull": {"active_plans": plan_id}},
    )

    return {"status": True}



# ==========================
#       plan/active
# ==========================
@router.post("/plan/active", status_code=200)
async def get_active_plan(payload: User) -> dict:
    ok, user_id = session.verify_session(payload.token)

    if not ok or not user_id:
        raise HTTPException(status_code=401, detail="Invalid or missing token")

    # 1. Get the active plans
    user = db.find_one(
        table_name="users",
        filters={"user_id": user_id},
        projection={"_id": False, "active_plans": True},
    )
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    all_plans: list[dict] = []

    for plan_id in user.get("active_plans", []):
        # get the plan
        plan = db.find_one(
            table_name="plans",
            filters={"user_id": user_id, "plan_id": plan_id, "deleted": False},
            projection={
                "_id": False,
                "plan_id": True,
                "created_at": True,
                "expected_complete": True,
                "n_tasks": True,
                "n_tasks_done": True,
                "n_replans": True,
                "deleted": True,
                "tasks": True,
            },
        )
        if not plan:
            logger.warning(
                f"Active plan '{plan_id}' for user '{user_id}' not found in plans collection"
            )
            all_plans.append({"plan_id": plan_id, "error": "Plan not found"})
            continue

        # 2. Get ALL tasks for this plan (non-deleted)
        tasks_list = db.find_many(
            table_name="tasks",
            filters={
                "user_id": user_id,
                "plan_id": plan_id,
                "deleted": False,
            },
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
            },
        )

        if not tasks_list:
            logger.warning(
                f"Failed to fetch tasks for plan '{plan_id}' of user '{user_id}'"
            )

        plan["tasks_all_info"] = tasks_list or []
        all_plans.append(plan)

    return {"status": True, "plans": all_plans}


# ==========================
#          replan
# ==========================
@router.post("/prompt/replan", status_code=200)
async def replan(payload: Replan) -> dict:
    plan_id = payload.plan_id
    new_goal = payload.new_goal
    ok, user_id = session.verify_session(payload.token)
    if not ok or not user_id:
        raise HTTPException(status_code=401, detail="Invalid or missing token")

    # 1. Retrieve the plan from the DB
    plan = db.find_one(
        table_name="plans",
        filters={"user_id": user_id, "plan_id": plan_id, "deleted": False},
        projection={
            "_id": False,
            "prompts": True,
            "responses": True,
            "n_tasks": True,
            "next_task_id": True,
            "n_tasks_done": True,
            "completed_at": True,
        },
    )
    if not plan_id or plan is None:
        raise HTTPException(status_code=402, detail="Invalid Plan ID")
    
    # 2. Create the history for the LLM
    prompts = plan.get("prompts") or []
    responses = plan.get("responses") or []
    if prompts and responses:
        history = {
            "last_prompt": prompts[-1],
            "last_response": responses[-1],
        }
    else:
        history = {}

    # 3. Communication with the LLM server
    llm_payload = {
        "goal": new_goal,
        "level": "0",  # Default to beginner
        "history": history,
        "user_info": dh.get_user_info(user_id),
    }
    llm_resp = llm.get_llm_response(llm_payload)
    if not llm_resp.get("status"):
        err_msg = llm_resp.get("error", "Unknown error from LLM service")
        logger.error(f"LLM service error for user {user_id}: {err_msg}")
        raise HTTPException(status_code=502, detail=f"LLM service error: {err_msg}")

    new_tasks_dict: Dict[str, Dict[str, Any]] = dict(llm_resp["result"]["tasks"])

    # 4. Mark existing tasks as deleted
    db.update_many_filtered(
        table_name="tasks",
        filter={"plan_id": plan_id, "user_id": user_id, "deleted": False},
        update={"$set": {"deleted": True}},
    )

    # 5. Insert new tasks with unique IDs --> use next_task_id if present, otherwise fallback to previous n_tasks
    start_task_id = int(plan.get("next_task_id", plan.get("n_tasks", 0) or 0))

    # 6. Create the new tasks
    tasks: List[Dict[str, Any]] = []
    for i, (date, task) in enumerate(new_tasks_dict.items()):
        timing.from_iso_to_datetime(date)
        difficulty = CHALLENGES_DIFFICULTY_MAP.get(str(task["difficulty"]).lower(), 1)
        tasks.append(
            {
                "task_id": start_task_id + i,
                "plan_id": plan_id,
                "user_id": user_id,
                "title": task["title"],
                "description": task["description"],
                "difficulty": difficulty,
                "score": difficulty * 10,
                "deadline_date": date,
                "completed_at": None,
                "deleted": False,
            }
        )
    db.insert_many("tasks", tasks)

    # 7. Update the plan
    db.find_one_and_update(
        table_name="plans",
        keys_dict={"user_id": user_id, "plan_id": plan_id},
        values_dict={
            "$inc": {"n_replans": 1},
            "$set": {
                # replan defines a NEW current set of tasks
                "n_tasks": len(new_tasks_dict),
                "n_tasks_done": 0,
                "completed_at": None,
                "next_task_id": start_task_id + len(new_tasks_dict),
            },
            "$push": {
                "prompts": llm_resp["result"]["prompt"],
                "responses": llm_resp["result"]["response"],
                "tasks": {
                    date: [task] for date, task in new_tasks_dict.items()
                },
            },
        },
        return_policy=ReturnDocument.AFTER,
    )

    safe_tasks = [{k: v for k, v in task.items() if k != "_id"} for task in tasks]
    return {
        "status": True,
        "plan_id": plan_id,
        "tasks": safe_tasks,
        "data": llm_resp["result"],
        "prompt": llm_resp["result"].get("prompt"),
    }
