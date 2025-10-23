import uuid
import os
import base64
import hashlib
import secrets
import re
import json
import threading
import datetime
from typing import Dict, Optional
from fastapi import FastAPI, Header, HTTPException
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

def verify_session(token: str):
    session = sessions_collection.find_one({"token": token})
    if not session:
        return [False, ""]
    return [True, session.get("user_id")]

def leaderboard_upsert_and_trim(*, user_id: str, score: int, K: int = LEADERBOARD_K) -> None:
    leaderboard_collection.update_one({"user_id": user_id}, {"$set": {"score": int(score)}}, upsert = True)
    total = leaderboard_collection.estimated_document_count()
    if total <= K:
        return
    keep_docs = list(leaderboard_collection.find({}, {"user_id": 1}).sort([("score", -1), ("user_id", 1)]).limit(K))
    keep_ids = [d["user_id"] for d in keep_docs]
    leaderboard_collection.delete_many({"user_id": {"$nin": keep_ids}})

def hash_password(password: str) -> str:
    if not check_register_password(password):
        raise ValueError("Too weak password")
    salt = os.urandom(32) # 32 bytes salt
    try:
        key = hashlib.scrypt(password.encode(encoding = 'utf-8', errors = 'strict'), salt = salt, n = SCRYPT_N,r = SCRYPT_R, p = SCRYPT_P)
        return base64.b64encode(salt + key).decode(encoding = 'utf-8')
    except ValueError as e:
        raise ValueError(f"Hashing error: {e}") from e

def verify_password(hash: str, non_hash: str) -> bool:
    data = base64.b64decode(hash.encode(encoding = 'utf-8', errors = 'strict'))
    salt, stored_key = data[:32], data[32:]
    new_key = hashlib.scrypt(non_hash.encode(encoding = 'utf-8', errors = 'strict'), salt = salt, n = SCRYPT_N, r = SCRYPT_R, p = SCRYPT_P)
    return secrets.compare_digest(new_key, stored_key)

def generate_token() -> str:
    # 256-bit+ token, URL-safe
    return secrets.token_urlsafe(48)

def check_register_password(password: str) -> bool:
    if not isinstance(password, str) or len(password) < MIN_LEN_PASSWORD:
        return False
    if not re.search(r'[A-Z]', password):  # at least one uppercase
        return False
    if not re.search(r'[a-z]', password):  # at least one lowercase
        return False
    if not re.search(r'\d', password):     # at least one digit
        return False
    return True

app = FastAPI(title = "Skill-Up Server", version = "1.0")


User_Info = Dict[str, Dict[str, int]]

class LoginInput(BaseModel):
    username: str
    password: str

class RegisterInput(BaseModel):
    username: str
    password: str
    user_info: User_Info

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


@app.post("/register", status_code=201)
def register_user(input: RegisterInput) -> Dict[str, str]:
    username = input.username.strip()
    password = input.password
    user_info = input.user_info
    if not username or not password:
        raise HTTPException(status_code = 400, detail = "Username and password are required")
    if user_collection.find_one({"username": username}):
        raise HTTPException(status_code = 400, detail = "User already exists")
    if not check_register_password(password):
        raise HTTPException(status_code = 400, detail = "Password does not meet complexity requirements")
    user_id = str(uuid.uuid4())
    password_hash = hash_password(password)
    user_collection.insert_one({"username": username, "password_hash": password_hash, "user_id": user_id})
    user_data_collection.insert_one({"user_id": user_id, "info": user_info, "score" : 0})
    return {"id": user_id, "username": username}

@app.post("/login")
def login_user(creds: LoginInput) -> Dict[str, str]:
    username = creds.username.strip()
    if not username or not creds.password:
        raise HTTPException(status_code=400, detail="Username and password are required")
    user = user_collection.find_one({"username": username})
    if not user or not verify_password(user.get("password_hash", ""), creds.password):
        raise HTTPException(status_code=401, detail="Invalid username or password")
    user_id = user["user_id"]
    for _ in range(6):
        token = generate_token()
        try:
            sessions_collection.insert_one({"token": token, "user_id": user_id, "created_at": datetime.datetime.now(UTC)})
            break
        except pymongo_errors.DuplicateKeyError:
            token = None  # try again
    else:
        raise HTTPException(status_code=500, detail="Could not create a session token")
    return {"token": token, "id": user_id, "username": username}

@app.post("/task_done")
def task_done(input: TaskDone):
    token = input.token
    task_idx = input.task_idx
    valid_token, user_id = verify_session(token)
    if not valid_token:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    user_info = user_data_collection.find_one({"user_id": user_id})
    today_tasks = user_info.get("tasks").get(str(datetime.date.today()))
    today_tasks[task_idx].done = True
    user_info.score += today_tasks[task_idx].score

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
