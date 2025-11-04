import uuid
import os
import base64
import hashlib
import secrets
import re
import json
import threading
import datetime
from typing import Any, Dict, Optional
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from pymongo import MongoClient, errors as pymongo_errors  # type: ignore
from datetime import timezone as _tz
UTC = _tz.utc

MONGO_URI = "mongodb://localhost:27017"
MONGO_DB = "skillup"
try:
    mongo_client = MongoClient(MONGO_URI)
    mongo_db = mongo_client[MONGO_DB]
    user_collection = mongo_db["users"]
    sessions_collection = mongo_db["sessions"]
    user_data_collection = mongo_db["user_data"]
    leaderboard = mongo_db["leaderboard"]
except Exception:
    print("Warning: Could not connect to MongoDB.")
    exit(1)

SCRYPT_N = 2**14  # CPU/memory cost factor
SCRYPT_R = 8      # block size
SCRYPT_P = 8      # parallelization factor
MIN_LEN_PASSWORD = 8
LEADERBOARD_K = 10


app = FastAPI(title = "Skill-Up Server", version = "1.0")


User_Info = Dict[str, Dict[str, int]]

class LoginInput(BaseModel):
    username: str
    password: str

class RegisterInput(BaseModel):
    username: str
    password: str
    email: str

class PromptInput(BaseModel):
    username: str
    token: str
    prompt: str

class ScoreUpdateInput(BaseModel):
    username: str
    token: str

class TaskDone(BaseModel):
    token: str
    task_idx: str

class CheckBearer(BaseModel):
    username: Optional[str] = None
    token: str


@app.post("/task_done")
def task_done(input: TaskDone):
    # WRONG FUNCTION, NEED TO BE REDONE
    ok, user_id = verify_session(input.token)
    if not ok: raise HTTPException(401, "Invalid or missing token")
    date = input.date or datetime.datetime.now(UTC).date().isoformat()
    ud = user_data_collection.find_one({"user_id": user_id}, {"tasks."+date: 1, "score": 1})
    if not ud or date not in ud.get("tasks", {}):
        raise HTTPException(404, "No tasks for date")
    tasks = ud["tasks"][date]
    if input.task_idx < 0 or input.task_idx >= len(tasks):
        raise HTTPException(400, "task_idx out of bounds")
    task = tasks[input.task_idx]
    if task.get("done"): raise HTTPException(409, "Task already done")
    task["done"] = True
    task["completed_at"] = datetime.datetime.now(UTC)
    # Persist task change and increment score in one update
    user_data_collection.update_one({"user_id": user_id},{"$set": {f"tasks.{date}.{input.task_idx}": task},"$inc": {"score": int(task.get("score", 0))}})
    leaderboard.update_one({"user_id": user_id}, {"$set": {"score": ud["score"] + task.get("score", 0)}}, upsert=True)
    leaderboard_upsert_and_trim(user_id=user_id, score=ud["score"] + task.get("score", 0))
    return {"score": ud["score"] + task.get("score", 0), "task": task}

@app.post("/prompt")
def get_llm_response(input: PromptInput) -> Dict[str, str]:
    username = input.username
    token = input.token
    prompt = input.prompt
    valid_token, user_id = verify_session(token)
    if not valid_token:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    user_info = user_data_collection.find_one({"user_id": user_id})
    if not user_info:
        user_info = {}
    # Manda un JSON al server LLM e ottieni la risposta
    request_data = {"prompt": prompt, "user_info": user_info}
    # Qui dovresti implementare la chiamata al server di mos
    llm_response = send_json_to_llm_server(request_data)
    return {"llm_response": llm_response}