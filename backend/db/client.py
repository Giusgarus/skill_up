import os
from typing import Optional
from pymongo import MongoClient
from pymongo.database import Database
from pymongo.collection import Collection

_client: Optional[MongoClient] = None
_db: Optional[Database] = None

def connect(reset: bool = False) -> None:
    global _client, _db
    # Case of reset of the DB connection
    if reset:
        close()
    if not reset and _client is not None and _db is not None:
        return
    # Initializations of global variables
    mongo_db = os.getenv("MONGO_DB", "skillup")
    mongo_uri = os.getenv("MONGO_URI", "mongodb://localhost:27017")
    # Create a new client and set the database connection
    if _client is None:
        try:
            _client = MongoClient(mongo_uri, serverSelectionTimeoutMS=3000)
            _client.admin.command("ping")
        except Exception:
            _client = _db = None
            return
    if _db is None:
        _db = _client[mongo_db]

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
