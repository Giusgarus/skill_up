import os
from typing import Optional
from pymongo import MongoClient
from pymongo.database import Database
from pymongo.collection import Collection

_client: Optional[MongoClient] = None
_db: Optional[Database] = None
MONGO_DB = None
MONGO_URI = None

def connect(reset: bool = False) -> None:
    global _client, _db, MONGO_DB, MONGO_URI, USERS_COLL, SESSIONS_COLL, USER_DATA_COLL, LEADERBOARD_COLL
    # Case of reset of the DB connection
    if reset:
        close()
    if not reset and _client is not None and _db is not None \
        and None not in [MONGO_DB, MONGO_URI, USERS_COLL, SESSIONS_COLL, USER_DATA_COLL, LEADERBOARD_COLL]:
        return
    # Initializations of global variables
    MONGO_DB = os.getenv("MONGO_DB", "skillup")
    MONGO_URI = os.getenv("MONGO_URI", "mongodb://localhost:27017")
    # Create a new client and set the database connection
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
    return _client

def get_db() -> Optional[Database]:
    return _db

def get_collection(coll_name: str) -> Optional[Collection]:
    if _db is None:
        return None
    if coll_name not in ["users", "sessions", "user_data", "leaderboard"]:
        return None
    return _db[coll_name]

def close() -> None:
    global _client, _db
    if _client:
        _client.close()
    _client = None
    _db = None

def ping() -> bool:
    if _client is None:
        return False
    try:
        _client.admin.command("ping")
        return True
    except Exception:
        return False
