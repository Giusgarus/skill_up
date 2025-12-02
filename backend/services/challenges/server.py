import json
import logging
from pathlib import Path
from statistics import mean
from datetime import timedelta, date as date_cls
from fastapi import APIRouter, HTTPException, Path as FastAPIPath
import backend.db.database as db
import backend.utils.session as session
import backend.utils.timing as timing
from pydantic import BaseModel, ConfigDict, Field
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
    token: str = Field(..., description="User session token (Bearer).")

class Goal(User):
    goal: str = Field(..., description="User goal used to generate the plan.")

class Plan(User):
    plan_id: int = Field(..., description="Identifier of the plan associated with the user.")

class Task(Plan):
    task_id: int = Field(..., description="Identifier of the task inside the plan.")
    medal_taken: Optional[str] = Field(
        None,
        description="Deprecated: medal is computed server-side based on daily completion.",
    )

class Report(Task):
    report: str = Field(..., description="User feedback text for the completed task.")

class Replan(Plan):
    new_goal: str = Field(..., description="New goal to regenerate the existing plan.")

class Retask(Task):
    modification_reason: str = Field(..., description="New prompt of the used with which regenerate the task.")
    
class HardPlan(User):
    preset: str = Field(..., description="Preset key used to create a predefined plan.")


class StatusResponse(BaseModel):
    status: bool = Field(..., description="Outcome of the request.")


class ScoreResponse(StatusResponse):
    score: int = Field(..., description="Updated user score.")


class PlanCreationResponse(StatusResponse):
    model_config = ConfigDict(extra="allow")
    plan_id: int = Field(..., description="Identifier of the created plan.")
    prompt: Optional[str] = Field(None, description="Prompt used to generate the plan.")
    response: Optional[Any] = Field(None, description="Response from the model or preset.")
    tasks: list[dict[str, Any]] | dict[str, Any] = Field(
        ...,
        description="Generated or inserted tasks; structure depends on the source.",
    )


class ActivePlansResponse(StatusResponse):
    model_config = ConfigDict(extra="allow")
    plans: List[Dict[str, Any]] = Field(..., description="List of active plans with their tasks.")


class ReplanResponse(StatusResponse):
    model_config = ConfigDict(extra="allow")
    plan_id: int = Field(..., description="Identifier of the replanned plan.")
    tasks: List[Dict[str, Any]] = Field(..., description="New tasks inserted into the plan.")
    data: Dict[str, Any] = Field(..., description="Payload returned by the LLM.")
    prompt: Optional[str] = Field(None, description="Prompt used during replanning.")


class ErrorResponse(BaseModel):
    detail: str = Field(..., description="Error detail.")


# ===============================
#        Fast API Router
# ===============================
router = APIRouter(prefix="/services/challenges", tags=["Challenges"])

def _normalize_tasks_or_throw(
    raw_tasks: Any,
    fallback_error: str | None = None,
) -> List[tuple[str, Dict[str, Any]]]:
    """Validate and normalize a raw tasks payload into a list of (date, task) tuples."""
    try:
        tasks_dict = dict(raw_tasks or {})
    except Exception as exc:  # pragma: no cover - defensive against malformed payloads
        logger.error("Invalid tasks payload from LLM: %s", exc)
        raise HTTPException(status_code=502, detail="Invalid tasks payload while creating the plan")

    # Remove potential Mongo metadata and early-exit on empty payloads
    tasks_dict.pop("_id", None)
    if not tasks_dict:
        raise HTTPException(status_code=502, detail="Plan generation returned no tasks.")

    normalized: List[tuple[str, Dict[str, Any]]] = []
    for date, task in tasks_dict.items():
        if not isinstance(task, dict):
            logger.warning("Skipping task for date %s because payload is not a dict", date)
            continue
        try:
            timing.from_iso_to_datetime(date)  # validate date format
        except Exception:
            logger.warning("Skipping task with invalid date key %s", date)
            continue

        title = (task.get("title") or "").strip()
        description = (task.get("description") or "").strip()
        if not title or not description:
            logger.warning("Skipping task for %s because title/description is missing", date)
            continue

        difficulty_raw = task.get("difficulty", "easy")
        normalized.append(
            (
                date,
                {
                    **task,
                    "title": title,
                    "description": description,
                    "difficulty": difficulty_raw,
                },
            )
        )

    if not normalized:
        raise HTTPException(
            status_code=502,
            detail=fallback_error or "Plan generation returned no valid tasks.",
        )
    return normalized


def _medal_grade(completed: int, total: int) -> str:
    """Compute medal grade (G/S/B/None) based on completion ratio."""
    if total <= 0 or completed <= 0:
        return "None"
    ratio = completed / total
    if ratio >= 1.0:
        return "G"
    if ratio >= 0.66:
        return "S"
    if ratio >= 0.33:
        return "B"
    return "None"


def _day_from_iso(value: Optional[str]) -> str:
    try:
        return timing.from_iso_to_datetime(value).date().isoformat()
    except Exception:
        return timing.now().date().isoformat()


def _extract_error_message(payload: Dict[str, Any] | None) -> str | None:
    if not payload:
        return None
    if isinstance(payload.get("error_message"), str):
        return payload.get("error_message")
    if isinstance(payload.get("response"), dict):
        resp = payload.get("response")
        if isinstance(resp.get("error_message"), str):
            return resp.get("error_message")
    return None


def _insert_plan_for_user(
    user_id: str,
    tasks_dict: Dict[str, Dict[str, Any]],
    prompt_text: str | None = None,
    response_payload: Any = None,
    fallback_error: str | None = None,
) -> Dict[str, Any]:
    """Create plan and tasks for a user given a tasks dict (date -> task)."""
    normalized_tasks = _normalize_tasks_or_throw(tasks_dict, fallback_error)

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
        for _, task in normalized_tasks
    ]

    res = db.insert(
        table_name="plans",
        record={
            "plan_id": plan_id,
            "user_id": user_id,
            "n_tasks": len(normalized_tasks),  # current tasks count
            "n_tasks_done": 0,
            "responses": [response_payload],
            "prompts": [prompt_text],
            "deleted": False,
            "difficulty": round(mean(difficulty_values)) if difficulty_values else 1,
            "created_at": timing.now_iso(),
            "expected_complete": timing.get_last_date([date for date, _ in normalized_tasks]),
            "n_replans": 0,
            "tasks": [{date: [task] for date, task in normalized_tasks}],
            "next_task_id": len(normalized_tasks), # keep a running task id counter for uniqueness across replans
            "completed_at": None,
        },
    )
    if not res:
        raise HTTPException(
            status_code=505, detail="Database error while creating plan"
        )

    # Create tasks
    tasks: List[Dict[str, Any]] = []
    for i, (date, task) in enumerate(normalized_tasks):
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
#           retask
# ==========================
@router.post(
    "/retask",
    status_code=200,
    summary="Regenerate a single task from a new goal",
    description=(
        "Regenerates the content of a single task within an existing plan using a new user goal.  \n"
        "- Validates the session token and the ownership of the plan/task.  \n"
        "- Builds a conversation history from previous prompts and responses stored in the plan.  \n"
        "- Calls the LLM service with the new goal and history to obtain a replacement task.  \n"
        "- Updates the task title, description, difficulty and score, resetting its completion status.  \n"
        "- Appends a note to the last stored plan prompt to record that the task has been modified."
    ),
    operation_id="retaskTask",
    response_model=Dict[str, Any],
    responses={
        200: {
            "description": (
                "Task successfully regenerated.  \n"
                "Returns a status flag, the updated prompt string and the new task payload."
            )
        },
        401: {"model": ErrorResponse, "description": "Invalid or missing token."},
        402: {
            "model": ErrorResponse,
            "description": "Missing Plan ID in the request payload.",
        },
        403: {
            "model": ErrorResponse,
            "description": "Missing Task ID in the request payload.",
        },
        404: {
            "model": ErrorResponse,
            "description": "Task not found, not owned by the user, or already deleted.",
        },
        405: {
            "model": ErrorResponse,
            "description": "Plan not found, not owned by the user, or marked as deleted.",
        },
        406: {
            "model": ErrorResponse,
            "description": "Database error while updating the task with the new content.",
        },
        407: {
            "model": ErrorResponse,
            "description": "Plan has no prompts history while at least one prompt is expected.",
        },
        408: {
            "model": ErrorResponse,
            "description": "Plan not found while updating the prompts history.",
        },
        501: {
            "model": ErrorResponse,
            "description": "LLM service error while generating the new task.",
        },
    },
)
async def retask(payload: Retask) -> dict:
    ok, user_id = session.verify_session(payload.token)
    plan_id = payload.plan_id
    task_id = payload.task_id
    modification_reason = payload.modification_reason
    if not ok or not user_id:
        raise HTTPException(status_code=401, detail="Invalid or missing token")
    if plan_id is None:
        raise HTTPException(status_code=402, detail="Missing Plan ID")
    if task_id is None:
        raise HTTPException(status_code=403, detail="Missing Task ID")
    
    # 1. Get the task
    task = db.find_one(
        table_name="tasks",
        filters={"task_id": task_id, "user_id": user_id, "plan_id": plan_id, "deleted": False},
        projection={
            "_id": False, 
            "title": True,
            "description": True,
            "difficulty": True,
            "score": True
        }
    )
    if not task or task is None:
        raise HTTPException(status_code=404, detail="Invalid task ID")

    # 2. Get the plan
    plan = db.find_one(
        table_name="plans",
        filters={"user_id": user_id, "plan_id": plan_id, "deleted": False},
        projection={
            "_id": False,
            "prompts": True,
            "responses": True,
            "completed_at": True,
        },
    )
    if not plan or plan is None:
        raise HTTPException(status_code=405, detail="Invalid plan ID")
    
    # 3. Create the history for the LLM
    prompts = plan.get("prompts") or []
    responses = plan.get("responses") or []
    history = [
        {"prompt": prompt, "response": response}
        for prompt, response in zip(prompts, responses)
        if prompt is not None or response is not None
    ]

    # 3. Communication with the LLM server
    llm_payload = {
        "goal": prompts[-1],
        "level": plan.get("difficulty"),
        "history": history,
        "user_info": dh.get_user_info(user_id),
        "previous_task": task,
        "modification_reason": modification_reason
    }
    response = llm.get_llm_retask_response(llm_payload)
    if not response.get("status"):
        err_msg = response.get("error", "Unknown error from LLM service")
        logger.error(f"LLM service error for user {user_id}: {err_msg}")
        raise HTTPException(status_code=501, detail=f"LLM service error: {err_msg}")

    # 4. Update task
    result: Dict[str, Any] = response.get("result") or {}
    new_difficulty = CHALLENGES_DIFFICULTY_MAP.get(str(result.get("difficulty", "easy")).lower(), 1)
    new_task = {
        "title": result["challenge_title"],
        "description": result["challenge_description"],
        "difficulty": new_difficulty,
        "score": new_difficulty * 10,
        "deadline_date": result["deadline_date"],
        "completed_at": None
    }
    updated_task = db.update_one(
        table_name="tasks",
        keys_dict={"task_id": task_id, "user_id": user_id, "plan_id": plan_id},
        values_dict={"$set": new_task}
    )
    if updated_task.matched_count == 0:
        raise HTTPException(status_code=406, detail="Error while updating task")
    
    # 5. Update plan (append the prompt of the user in the last prompt of the plan)
    if not prompts:
        raise HTTPException(status_code=407, detail="Plan has no prompts but should have at least one.")
    prompts = prompts[:-1] + [f"{str(prompts[-1])}\nTask {task_id} modified with respect to this information: {modification_reason}."]
    updated_plan = db.find_one_and_update(
        table_name="plans",
        keys_dict={"user_id": user_id, "plan_id": plan_id},
        values_dict={"$set": {"prompts": prompts}},
        projection={"_id": False, "prompts": True},
        return_policy=ReturnDocument.AFTER,
    )
    if not updated_plan:
        raise HTTPException(status_code=408, detail="Plan not found")

    return {
        "status": True,
        "new_prompt": prompts[-1],
        "new_task": new_task
    }


# ==========================
#         task_done
# ==========================
@router.post(
    "/task_done",
    status_code=200,
    summary="Mark task as done",
    description=(
        "Marks a task as completed and updates user score, plan stats, and leaderboard.  \n"
        "- Validates session token and plan/task identifiers.  \n"
        "- Updates completion counters, medals, and leaderboard automatically.  \n"
        "- Keeps the leaderboard sorted by score."
    ),
    operation_id="completeTask",
    response_model=ScoreResponse,
    responses={
        401: {"model": ErrorResponse, "description": "Invalid or missing token."},
        402: {"model": ErrorResponse, "description": "Invalid plan."},
        403: {"model": ErrorResponse, "description": "Invalid task."},
        404: {"model": ErrorResponse, "description": "Task not found or not completable."},
        405: {"model": ErrorResponse, "description": "Plan not found."},
        406: {"model": ErrorResponse, "description": "User not found after update."},
        407: {"model": ErrorResponse, "description": "Invalid user projection after update."},
    },
)
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
        projection={"_id": False, "score": True, "deadline_date": True},
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
    
    # 4. Update medals (computed server-side)
    day_str = _day_from_iso(task.get("deadline_date"))
    try:
        tasks_same_day = db.find_many(
            table_name="tasks",
            filters={
                "user_id": user_id,
                "deleted": False,
                "deadline_date": {"$regex": f"^{day_str}"},
            },
            projection={"_id": False, "completed_at": True, "task_id": True},
        )
        tasks_same_day = tasks_same_day or []
        total = len(tasks_same_day)
        completed = len([t for t in tasks_same_day if t.get("completed_at") is not None])
        present = any(t.get("task_id") == task_id for t in tasks_same_day)
        if not present:
            total += 1  # include the task we just completed
            completed += 1
        if total == 0:
            return {"status": True, "score": user["score"]}
        medal_grade = _medal_grade(completed, total)

        # remove any stale entry for this task, then append if a medal is earned
        db.update_one(
            table_name="medals",
            keys_dict={"user_id": user_id, "timestamp": day_str},
            values_dict={"$pull": {"medal": {"task_id": task_id}}},
        )
        if medal_grade != "None":
            db.update_one(
                table_name="medals",
                keys_dict={"user_id": user_id, "timestamp": day_str},
                values_dict={
                    "$push": {"medal": {"grade": medal_grade, "task_id": task_id}}
                },
                upsert=True,
            )
    except Exception as exc:
        logger.error("Failed to compute/update medal for user %s: %s", user["username"], exc)

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
@router.post(
    "/task_undo",
    status_code=200,
    summary="Undo task completion",
    description=(
        "Restores an already completed task to incomplete state.  \n"
        "- Validates session token and plan/task identifiers.  \n"
        "- Decrements score and counters, reactivating the plan when needed.  \n"
        "- Updates the leaderboard accordingly."
    ),
    operation_id="undoTaskCompletion",
    response_model=ScoreResponse,
    responses={
        401: {"model": ErrorResponse, "description": "Invalid or missing token."},
        402: {"model": ErrorResponse, "description": "Invalid plan."},
        403: {"model": ErrorResponse, "description": "Invalid task."},
        404: {"model": ErrorResponse, "description": "Task not completed or not found."},
        405: {"model": ErrorResponse, "description": "Plan not found."},
        406: {"model": ErrorResponse, "description": "User not found after update."},
        407: {"model": ErrorResponse, "description": "Invalid user projection after update."},
    },
)
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
        projection={"_id": False, "score": True, "completed_at": True, "deadline_date": True},
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
    completion_day = _day_from_iso(task_doc.get("deadline_date"))
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
@router.post(
    "/report",
    status_code=200,
    summary="Submit task report",
    description=(
        "Stores textual feedback for a task belonging to an active plan.  \n"
        "Requires a valid token and existing plan/task identifiers."
    ),
    operation_id="reportTaskFeedback",
    response_model=StatusResponse,
    responses={
        401: {"model": ErrorResponse, "description": "Invalid or missing token."},
        503: {"model": ErrorResponse, "description": "Database error or invalid plan."},
    },
)
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
@router.post(
    "/prompt",
    status_code=200,
    summary="Generate a personalized plan",
    description=(
        "Calls the LLM engine to generate a new plan from the user's goal.  \n"
        "- Validates the session token.  \n"
        "- Saves plan and generated tasks with difficulty and score.  \n"
        "- Returns the created plan with task references."
    ),
    operation_id="generatePlan",
    response_model=PlanCreationResponse,
    responses={
        401: {"model": ErrorResponse, "description": "Invalid or missing token."},
        502: {"model": ErrorResponse, "description": "LLM service error."},
        503: {"model": ErrorResponse, "description": "Invalid user or missing plan data."},
        505: {"model": ErrorResponse, "description": "Database error while creating the plan."},
    },
)
def get_prompt(payload: Goal) -> dict:
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
        "history": [],  # empty because this is a new plan
        "user_info": dh.get_user_info(user_id),
    }
    llm_resp = llm.get_llm_response(llm_payload)
    if not llm_resp.get("status"):
        err_msg = llm_resp.get("error", "Unknown error from LLM service")
        logger.error(f"LLM service error for user {user_id}: {err_msg}")
        raise HTTPException(status_code=502, detail=f"LLM service error: {err_msg}")
    
    # 3. Validation of the result
    result_payload = llm_resp["result"]
    result_payload["prompt"] = user_goal
    is_valid, validation_error = llm.validate_challenges(result_payload)
    if not is_valid:
        logger.error("LLM response failed validation: %s -- response: %s", validation_error, str(result_payload)[:500])
        return {"status": False, "error": f"Invalid LLM response: {validation_error}"}
    tasks_payload = result_payload.get("tasks")
    if not tasks_payload:
        raise HTTPException(
            status_code=502,
            detail=_extract_error_message(result_payload) or "Plan generation returned no valid tasks.",
        )
    fallback_error = _extract_error_message(result_payload)
    return _insert_plan_for_user(
        user_id=user_id,
        tasks_dict=tasks_payload,
        prompt_text=result_payload.get("prompt"),
        response_payload=result_payload.get("response"),
        fallback_error=fallback_error,
    )


# ==========================
#       hardcoded plan
# ==========================
@router.post(
    "/hard/{preset}",
    status_code=200,
    summary="Create a preset plan",
    description=(
        "Creates a plan with predefined tasks using a hard preset (e.g., `hard1`, `hard2`).  \n"
        "Validates the session token before creating the plan and tasks."
    ),
    operation_id="createPresetPlan",
    response_model=PlanCreationResponse,
    responses={
        401: {"model": ErrorResponse, "description": "Invalid or missing token."},
        404: {"model": ErrorResponse, "description": "Plan preset not recognized."},
        503: {"model": ErrorResponse, "description": "Invalid user while creating the plan."},
        505: {"model": ErrorResponse, "description": "Database error while creating the plan."},
    },
)
async def create_hard_plan(
    preset: Annotated[str, FastAPIPath(description="Preset key to apply for the generated plan.")],
    payload: User,
) -> dict:
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
@router.post(
    "/plan/delete",
    status_code=200,
    summary="Delete a plan",
    description=(
        "Marks a plan as deleted and removes unfinished tasks from the active view.  \n"
        "Also updates the user's list of active plans."
    ),
    operation_id="deletePlan",
    response_model=StatusResponse,
    responses={
        401: {"model": ErrorResponse, "description": "Invalid or missing token."},
        404: {"model": ErrorResponse, "description": "Invalid or non-existent plan."},
    },
)
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
        # io qui metterei 404, ma se vuoi tenere 402 e' una scelta tua
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
@router.post(
    "/plan/active",
    status_code=200,
    summary="List active plans",
    description=(
        "Retrieves all active plans for the authenticated user with their non-deleted tasks.  \n"
        "If a plan is missing from storage, the entry is flagged in the list."
    ),
    operation_id="getActivePlans",
    response_model=ActivePlansResponse,
    responses={
        401: {"model": ErrorResponse, "description": "Invalid or missing token."},
        404: {"model": ErrorResponse, "description": "User not found."},
    },
)
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
@router.post(
    "/prompt/replan",
    status_code=200,
    summary="Replan an existing plan",
    description=(
        "Creates a new version of the plan from a new goal, marking previous tasks as deleted.  \n"
        "Increments the replan counter and adds tasks with sequential IDs."
    ),
    operation_id="replanExistingPlan",
    response_model=ReplanResponse,
    responses={
        401: {"model": ErrorResponse, "description": "Invalid or missing token."},
        402: {"model": ErrorResponse, "description": "Invalid or non-existent plan."},
        502: {"model": ErrorResponse, "description": "LLM service error during replan."},
    },
)
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
    history = [
        {"prompt": p, "response": r}
        for p, r in zip(prompts, responses)
        if p is not None or r is not None
    ]

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
    
    result_payload = llm_resp.get("result") or {}
    tasks_payload = result_payload.get("tasks")
    if not tasks_payload:
        raise HTTPException(
            status_code=502,
            detail=_extract_error_message(result_payload) or "Plan generation returned no valid tasks.",
        )
    fallback_error = _extract_error_message(result_payload)
    normalized_tasks = _normalize_tasks_or_throw(tasks_payload, fallback_error)

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
    for i, (date, task) in enumerate(normalized_tasks):
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
                "n_tasks": len(normalized_tasks),
                "n_tasks_done": 0,
                "completed_at": None,
                "next_task_id": start_task_id + len(normalized_tasks),
            },
            "$push": {
                "prompts": llm_resp["result"]["prompt"],
                "responses": llm_resp["result"]["response"],
                "tasks": {date: [task] for date, task in normalized_tasks},
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
