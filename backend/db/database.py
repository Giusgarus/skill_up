from pymongo import MongoClient
from typing import AsyncGenerator
from motor.motor_asyncio import AsyncIOMotorDatabase

async def init_database() -> None:
    pass

async def shutdown_database() -> None:
    pass

async def db_dependency() -> AsyncGenerator[AsyncIOMotorDatabase, None]:
    pass

def collection_dependency(name: str):
    pass

async def with_transaction(fn, *args, **kwargs):
    pass

def current_timestamp() -> object:
    pass

def create(url: str = "mongodb://localhost:27017", enable_drop: bool = False):
    client = MongoClient(url, serverSelectionTimeoutMS = 5000)
    client.admin.command("ping")  # sanity check

    # 1) Drop the database
    if enable_drop:
        client.drop_database("skillup")

    # 2) Create collections and indexes
    db = client["skillup"]
    users = db["users"]
    users.create_index("username", unique = True)
    sessions = db["sessions"]
    sessions.create_index("token", unique = True)
    sessions.create_index("created_at", expireAfterSeconds = 86400)  # your TTL here
    user_data = db["user_data"]
    user_data.create_index("user_id", unique = True)
    user_data.create_index([("score", -1), ("username", 1)])
    leaderboard = db["leaderboard"]
    leaderboard.create_index([("user_id", 1)], unique = True)
    leaderboard.create_index([("score", -1), ("user_id", 1)])

    print("skillup database recreated")
