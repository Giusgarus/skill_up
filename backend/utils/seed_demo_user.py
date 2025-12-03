"""
Seed a demo user with rich data (plans, tasks, medals, score) for live demos.

Usage (from repo root):
    python -m backend.utils.seed_demo_user --username demo --email demo@example.com
"""

import argparse
import asyncio
import uuid
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from typing import Iterable

from backend.db import client as db_client
from backend.db import database as db
from backend.services.challenges import server as challenges
from backend.utils import security, session, timing


@dataclass
class TaskSpec:
    offset: int
    hour: int
    title: str
    description: str
    difficulty: str


@dataclass
class DaySpec:
    date: date
    tasks: int
    complete: int
    goal: str
    difficulty: str


def _iso_at(base_day: date, offset: int, hour: int) -> str:
    dt = datetime.combine(
        base_day + timedelta(days=offset),
        time(hour=hour, minute=0, tzinfo=timezone.utc),
    )
    return dt.isoformat()


def _ensure_db() -> None:
    db_client.connect()
    mongo_db = db.connect_to_db()
    if mongo_db is None:
        raise RuntimeError("MongoDB connection not available; check MONGO_URI/MONGO_DB.")
    db.create_indexes(mongo_db)


def _ensure_leaderboard() -> None:
    db.update_one(
        table_name="leaderboard",
        keys_dict={"_id": "topK"},
        values_dict={"$setOnInsert": {"items": []}},
        upsert=True,
    )


def _purge_existing(username: str) -> None:
    mongo_db = db.connect_to_db()
    if mongo_db is None:
        return
    existing = db.find_one(
        table_name="users",
        filters={"username": username},
        projection={"_id": False, "user_id": True},
    )
    if not existing:
        return
    user_id = existing["user_id"]
    for coll in ("tasks", "plans", "medals", "sessions", "device_tokens"):
        mongo_db[coll].delete_many({"user_id": user_id})
    mongo_db["users"].delete_many({"username": username})
    db.update_one(
        table_name="leaderboard",
        keys_dict={"_id": "topK"},
        values_dict={"$pull": {"items": {"username": username}}},
    )


def _build_tasks(base_day: date, specs: Iterable[TaskSpec]) -> dict[str, dict[str, str]]:
    tasks: dict[str, dict[str, str]] = {}
    for spec in specs:
        deadline = _iso_at(base_day, spec.offset, spec.hour)
        tasks[deadline] = {
            "title": spec.title,
            "description": spec.description,
            "difficulty": spec.difficulty,
        }
    return tasks


async def _complete_tasks(
    token: str,
    plan_id: int,
    tasks_payload: list[dict],
    deadlines_to_complete: set[str],
) -> int:
    done = 0
    for task in tasks_payload:
        if task.get("deadline_date") not in deadlines_to_complete:
            continue
        payload = challenges.Task(
            token=token,
            plan_id=plan_id,
            task_id=int(task["task_id"]),
        )
        await challenges.task_done(payload)
        done += 1
    return done


def _create_user(username: str, password: str, email: str) -> str:
    user_id = str(uuid.uuid4())
    db.insert(
        table_name="users",
        record={
            "username": username,
            "password_hash": security.hash_password(password),
            "user_id": user_id,
            "email": email.strip().lower(),
            "n_plans": 0,
            "n_plans_done": 0,
            "n_tasks_done": 0,
            "creation_time_account": timing.now(),
            "profile_pic": None,
            "streak": 0,
            "score": 0,
            "name": "Demo",
            "surname": "User",
            "height": 180,
            "weight": 75,
            "sex": "M",
            "interests_info": [0, 2, 3, 5],
            "selections_info": [0, 2, 3, 5],
            "questions_info": [4, 3, 3, 2, 4, 3, 4, 3, 4, 3],
            "active_plans": [],
            "about": "Power user created for live demos.",
            "day_routine": "Morning workouts, deep work till lunch, lighter tasks in the afternoon.",
            "organized": "Loves checklists and short sprints.",
            "focus": "Ship features and stay healthy.",
            "age": 32,
            "onboarding_answers": "demo-seed",
            "medals": {},
        },
    )
    return user_id


def _update_user_counters(user_id: str) -> None:
    completed_plans = db.find_many(
        table_name="plans",
        filters={"user_id": user_id, "completed_at": {"$ne": None}},
        projection={"_id": False, "plan_id": True},
    )
    db.update_one(
        table_name="users",
        keys_dict={"user_id": user_id},
        values_dict={"$set": {"n_plans_done": len(completed_plans or [])}},
    )


def seed_demo_user(username: str, password: str, email: str) -> str:
    _ensure_db()
    _purge_existing(username)
    _ensure_leaderboard()

    user_id = _create_user(username, password, email)
    token = session.generate_session(user_id)

    today = timing.now_local().date()
    start_of_week = today - timedelta(days=today.weekday())  # Monday
    prev_week_start = start_of_week - timedelta(days=7)
    two_weeks_start = start_of_week - timedelta(days=14)

    # ---------- Historical plan (two weeks ago, fully completed: 2 tasks/day) ----------
    plan_hist_specs: list[TaskSpec] = []
    for i in range(7):
        day = two_weeks_start + timedelta(days=i)
        offset = (day - today).days
        plan_hist_specs.extend(
            [
                TaskSpec(
                    offset,
                    7,
                    f"Foundation block {i+1}",
                    "Kick off early and clear the runway.",
                    "easy" if i % 2 == 0 else "medium",
                ),
                TaskSpec(
                    offset,
                    18,
                    f"Lock-in recap {i+1}",
                    "Evening recap to close loops and prep tomorrow.",
                    "medium",
                ),
            ]
        )
    hist_tasks = _build_tasks(today, plan_hist_specs)
    hist_plan = challenges._insert_plan_for_user(
        user_id=user_id,
        tasks_dict=hist_tasks,
        prompt_text="Demo: retrospective sprint",
        response_payload={"source": "seed_script"},
        fallback_error=None,
    )
    hist_deadlines = {_iso_at(today, spec.offset, spec.hour) for spec in plan_hist_specs}
    asyncio.run(_complete_tasks(token, hist_plan["plan_id"], hist_plan["tasks"], hist_deadlines))

    # ---------- Previous week plan (gold every day: 3 tasks/day) ----------
    plan_prev_specs: list[TaskSpec] = []
    for i in range(7):
        day = prev_week_start + timedelta(days=i)
        offset = (day - today).days
        plan_prev_specs.extend(
            [
                TaskSpec(
                    offset,
                    7,
                    f"Momentum {i+1} AM",
                    "Prime the day with focused intent.",
                    "medium",
                ),
                TaskSpec(
                    offset,
                    12,
                    f"Momentum {i+1} MID",
                    "Ship something small and visible.",
                    "hard" if i % 3 == 0 else "medium",
                ),
                TaskSpec(
                    offset,
                    18,
                    f"Momentum {i+1} PM",
                    "Reset, reflect, and clear the board.",
                    "easy",
                ),
            ]
        )
    prev_tasks = _build_tasks(today, plan_prev_specs)
    prev_plan = challenges._insert_plan_for_user(
        user_id=user_id,
        tasks_dict=prev_tasks,
        prompt_text="Demo: momentum week",
        response_payload={"source": "seed_script"},
        fallback_error=None,
    )
    prev_deadlines = {_iso_at(today, spec.offset, spec.hour) for spec in plan_prev_specs}
    asyncio.run(_complete_tasks(token, prev_plan["plan_id"], prev_plan["tasks"], prev_deadlines))

    # ---------- Current week plan (active: gold on past days, silver today, future open) ----------
    current_specs: list[TaskSpec] = []
    for i in range(7):
        day = start_of_week + timedelta(days=i)
        offset = (day - today).days
        current_specs.extend(
            [
                TaskSpec(
                    offset,
                    7,
                    f"Showtime {i+1} AM",
                    "Set priorities and clear blockers fast.",
                    "medium" if i % 2 == 0 else "easy",
                ),
                TaskSpec(
                    offset,
                    12,
                    f"Showtime {i+1} MID",
                    "Demo-ready slice or customer follow-up.",
                    "hard" if i % 3 == 0 else "medium",
                ),
                TaskSpec(
                    offset,
                    18,
                    f"Showtime {i+1} PM",
                    "Evening tidy-up: notes, commits, prep tomorrow.",
                    "medium",
                ),
            ]
        )
    plan_tasks = _build_tasks(today, current_specs)
    plan = challenges._insert_plan_for_user(
        user_id=user_id,
        tasks_dict=plan_tasks,
        prompt_text="Demo: full week storyline",
        response_payload={"source": "seed_script"},
        fallback_error=None,
    )

    deadlines_to_complete = {
        _iso_at(today, spec.offset, spec.hour)
        for spec in current_specs
        if spec.offset < 0 or (spec.offset == 0 and spec.hour in {7, 12})
    }
    asyncio.run(_complete_tasks(token, plan["plan_id"], plan["tasks"], deadlines_to_complete))

    # ---------- Year-long highlights plan: spread medals across the full year ----------
    def add_highlights_plan(name: str, day_specs: list[DaySpec]) -> int:
        specs: list[TaskSpec] = []
        to_complete: set[str] = set()
        hours = [7, 12, 18, 15]
        for idx, ds in enumerate(day_specs):
            offset = (ds.date - today).days
            for j in range(ds.tasks):
                hour = hours[j % len(hours)]
                specs.append(
                    TaskSpec(
                        offset,
                        hour,
                        f"{ds.goal} {idx+1}-{j+1}",
                        f"{ds.goal} focus block",
                        ds.difficulty,
                    )
                )
                if j < ds.complete:
                    to_complete.add(_iso_at(today, offset, hour))
        tasks_dict = _build_tasks(today, specs)
        inserted = challenges._insert_plan_for_user(
            user_id=user_id,
            tasks_dict=tasks_dict,
            prompt_text=name,
            response_payload={"source": "seed_script", "plan": name},
            fallback_error=None,
        )
        asyncio.run(_complete_tasks(token, inserted["plan_id"], inserted["tasks"], to_complete))
        return inserted["plan_id"]

    current_year = today.year
    year_plan_ids: list[int] = []
    year_plan_ids.append(
        add_highlights_plan(
            "Yearly highlights Q1",
            [
                DaySpec(date(current_year, 1, 8), 3, 3, "January reset", "medium"),   # gold
                DaySpec(date(current_year, 2, 12), 3, 2, "February focus", "hard"),    # silver
                DaySpec(date(current_year, 3, 18), 3, 1, "March momentum", "medium"),  # bronze
                DaySpec(date(current_year, 4, 5), 3, 0, "April recharge", "easy"),     # none
            ],
        )
    )
    year_plan_ids.append(
        add_highlights_plan(
            "Yearly highlights Q2",
            [
                DaySpec(date(current_year, 5, 6), 3, 3, "May maker", "hard"),
                DaySpec(date(current_year, 6, 10), 3, 2, "June juggle", "medium"),
                DaySpec(date(current_year, 7, 14), 3, 1, "July joy", "easy"),
                DaySpec(date(current_year, 8, 3), 3, 0, "August unplugged", "easy"),
            ],
        )
    )
    year_plan_ids.append(
        add_highlights_plan(
            "Yearly highlights Q3",
            [
                DaySpec(date(current_year, 9, 9), 3, 3, "September shipping", "hard"),
                DaySpec(date(current_year, 10, 11), 3, 2, "October optimize", "medium"),
                DaySpec(date(current_year, 11, 7), 3, 1, "November nurture", "easy"),
                DaySpec(date(current_year, 12, 4), 3, 0, "December reset", "easy"),
            ],
        )
    )
    # Extra dense monthly plan with varied goals/completions to increase medals footprint
    year_plan_ids.append(
        add_highlights_plan(
            "Monthly streak boosters",
            [
                DaySpec(date(current_year, 1, 21), 4, 4, "Deep focus", "hard"),
                DaySpec(date(current_year, 2, 24), 4, 3, "Cardio push", "medium"),
                DaySpec(date(current_year, 3, 27), 4, 2, "Learning lab", "medium"),
                DaySpec(date(current_year, 4, 20), 4, 1, "Recovery day", "easy"),
                DaySpec(date(current_year, 5, 22), 4, 4, "Builder sprint", "hard"),
                DaySpec(date(current_year, 6, 25), 4, 3, "Social outreach", "easy"),
                DaySpec(date(current_year, 7, 19), 4, 2, "Nutrition reset", "medium"),
                DaySpec(date(current_year, 8, 23), 4, 1, "Declutter", "easy"),
                DaySpec(date(current_year, 9, 16), 4, 4, "Release polish", "hard"),
                DaySpec(date(current_year, 10, 21), 4, 3, "Creative jam", "medium"),
                DaySpec(date(current_year, 11, 18), 4, 2, "Skill drill", "medium"),
                DaySpec(date(current_year, 12, 15), 4, 1, "Gratitude recap", "easy"),
            ],
        )
    )
    # Seasonal surge plan to add more tasks/medals variety
    year_plan_ids.append(
        add_highlights_plan(
            "Seasonal surge",
            [
                DaySpec(date(current_year, 2, 5), 5, 5, "Winter intensity", "hard"),
                DaySpec(date(current_year, 5, 12), 5, 4, "Spring launch", "medium"),
                DaySpec(date(current_year, 8, 9), 5, 3, "Summer balance", "easy"),
                DaySpec(date(current_year, 11, 3), 5, 2, "Autumn wrap", "medium"),
            ],
        )
    )

    # Keep all plans visible/active for the demo (so past weeks show tasks too).
    db.update_one(
        table_name="users",
        keys_dict={"user_id": user_id},
        values_dict={
            "$addToSet": {
                "active_plans": {
                    "$each": [
                        hist_plan["plan_id"],
                        prev_plan["plan_id"],
                        plan["plan_id"],
                        *year_plan_ids,
                    ]
                }
            }
        },
    )

    _update_user_counters(user_id)
    return token


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Create a demo SkillUp user with tasks and medals.")
    parser.add_argument("--username", default="demo_user", help="Username to create/reset.")
    parser.add_argument("--password", default="DemoUser123!", help="Password to store (meets complexity rules).")
    parser.add_argument("--email", default="demo_user@example.com", help="Email for the demo user.")
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    try:
        token = seed_demo_user(args.username, args.password, args.email)
    except Exception as exc:
        raise SystemExit(f"Failed to seed demo user: {exc}") from exc
    print("Demo user created.")
    print(f"  username: {args.username}")
    print(f"  password: {args.password}")
    print(f"  session token (use for API calls): {token}")
