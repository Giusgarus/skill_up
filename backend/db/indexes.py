from typing import Optional
from pymongo.database import Database
from pymongo import ASCENDING

def create_indexes(db: Optional[Database]) -> None:
    if db is None:
        return
    # Esempi da modificare opportunamente
    db["users"].create_index([("email", ASCENDING)], unique=True, name="ux_users_email")
    db["tasks"].create_index([("user_id", ASCENDING), ("date", ASCENDING)], unique=True, name="ux_tasks_user_date")
    db["sessions"].create_index([("user_id", ASCENDING)], name="ix_sessions_user")
    db["user_data"].create_index([("user_id", ASCENDING)], name="ix_userdata_user")
    db["leaderboard"].create_index([("period", ASCENDING), ("score", ASCENDING)], name="ix_leaderboard_period_score")


