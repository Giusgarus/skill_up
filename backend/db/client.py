import os
from typing import Optional
from pymongo import MongoClient
from pymongo.database import Database
from pymongo.collection import Collection

_client: Optional[MongoClient] = None
_db: Optional[Database] = None
MONGO_DB = MONGO_URI = USERS_COLL = SESSIONS_COLL = USER_DATA_COLL = LEADERBOARD_COLL = None

def config_by_env(reset: bool = False) -> None:
    global _client, _db, MONGO_DB, MONGO_URI, USERS_COLL, SESSIONS_COLL, USER_DATA_COLL, LEADERBOARD_COLL
    # Case of reset of the DB connection
    if reset:
        close_client()
    if (
        not reset
        and _client is not None
        and _db is not None
        and None not in [MONGO_DB, MONGO_URI, USERS_COLL, SESSIONS_COLL, USER_DATA_COLL, LEADERBOARD_COLL]
    ):
        return
    # Initializations of global variables
    MONGO_DB = os.getenv("MONGO_DB", "skillup")
    MONGO_URI = os.getenv("MONGO_URI", "mongodb://localhost:27017")
    USERS_COLL = "users"
    SESSIONS_COLL = "sessions"
    USER_DATA_COLL = "user_data"
    LEADERBOARD_COLL = "leaderboard"
    # Create a new client and database
    if _client is None:
        try:
            _client = MongoClient(MONGO_URI, serverSelectionTimeoutMS=3000)
            _client.admin.command("ping")
        except Exception:
            _client = _db = None
            return
    if _db is None:
        _db = _client[MONGO_DB]

def get_client() -> Optional[MongoClient]:
    config_by_env()
    return _client

def get_db() -> Optional[Database]:
    config_by_env()
    return _db

def get_collection(coll_name: str) -> Optional[Collection]:
    config_by_env()
    if _db is None:
        return None
    return _db[coll_name]

def get_users() -> Optional[Collection]:
    return _db[USERS_COLL]

def get_sessions() -> Optional[Collection]:
    return _db[SESSIONS_COLL]

def get_user_data() -> Optional[Collection]:
    return _db[USER_DATA_COLL]

def get_leaderboard() -> Optional[Collection]:
    return _db[LEADERBOARD_COLL]

def close_client() -> None:
    global _client, _db
    if _client:
        _client.close()
    _client = None
    _db = None

def ping() -> bool:
    config_by_env()
    if _client is None:
        return False
    try:
        _client.admin.command("ping")
        return True
    except Exception:
        return False
