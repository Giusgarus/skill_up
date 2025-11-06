from typing import Optional
from pymongo.database import Database
from pymongo import ASCENDING, DESCENDING

def create_indexes(db: Optional[Database]) -> None:
    if db is None:
        return
    db["users"].create_index([("user_id", ASCENDING)], unique=True, name="users_index")
    db["tasks"].create_index([("user_id", ASCENDING), ("task_id", ASCENDING)], unique=True, name="tasks_index")
    db["sessions"].create_index([("token", ASCENDING)], name="sessions_index")
    db["leaderboard"].create_index([("username", ASCENDING)], unique = True, name="leaderboard_index")
    db["leaderboard"].create_index([("score", DESCENDING), ("username", ASCENDING)])


