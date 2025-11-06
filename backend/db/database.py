from pymongo import MongoClient, PyMongoError
from pymongo.database import Database
import db.client as client

table_primary_keys_dict = {
    "users": ["user_id"],
    "tasks": ["task_id", "user_id"],
    "sessions": ["token"],
    "leaderboard": ["user_id"],
}

def check_primary_keys(table_name: str, record: dict):
    primary_keys = table_primary_keys_dict[table_name]
    for k in primary_keys:
        if k not in record.keys():
            return False
    return True

def connect_to_db() -> Database:
    if not client.ping():
        client.connect()
    return client.get_db()

def insert(table_name: str, record: dict) -> dict:
    db = connect_to_db()
    if not check_primary_keys(table_name, record):
        raise RuntimeError(f"The primary keys {table_primary_keys_dict[table_name]} of '{table_name}' are required in the record field")
    try:
        return db[table_name].insert_one(record)
    except PyMongoError as e:
        raise RuntimeError(e)
    
def insert_many(table_name: str, records: list[dict]) -> list[dict]:
    results = []
    for record in records:
        result = insert(table_name, record)
        results.append(result)
    return results

def update(table_name: str, record: dict) -> dict:
    db = connect_to_db()
    if not check_primary_keys(table_name, record):
        raise RuntimeError(f"The primary keys {table_primary_keys_dict[table_name]} of '{table_name}' are required in the record field")
    primary_keys_dict = {}
    payload = {}
    for k, v in record.items():
        if k in primary_keys_dict[table_name]:
            primary_keys_dict[k] = v
        else:
            payload[k] = v
    try:
        return db[table_name].update_one(primary_keys_dict, {"$set": payload})
    except PyMongoError as e:
        raise RuntimeError(e)

def update_many(table_name: str, records: list[dict]) -> list[dict]:
    results = []
    for record in records:
        result = update(table_name, record)
        results.append(result)
    return results

def find_many(table_name: str, filters: dict = {}, projection: dict = None) -> list:
    db = connect_to_db()
    try:
        cursor = db[table_name].find_one(filter = filters, projection = projection) # automatically handles the None cases
        return list(cursor)
    except PyMongoError as e:
        raise RuntimeError(e)


def find_one(table_name: str, filters: dict = {}, projection: dict = None) -> list:
    db = connect_to_db()
    try:
        cursor = db[table_name].find_one(filter = filters, projection = projection) # automatically handles the None cases
        return cursor
    except PyMongoError as e:
        raise RuntimeError(e)


def create(url: str = "mongodb://localhost:27017", enable_drop: bool = False):
    client = MongoClient(url, serverSelectionTimeoutMS = 5000)
    client.admin.command("ping")
    # 1) Drop the database
    if enable_drop:
        client.drop_database("skillup")
    # 2) Create collections and indexes
    db = client["skillup"]
    users = db["users"]
    users.create_index("username", unique=True)
    sessions = db["sessions"]
    sessions.create_index("token", unique=True)
    sessions.create_index("created_at", expireAfterSeconds=86400)  # your TTL here
    user_data = db["user_data"]
    user_data.create_index("user_id", unique=True)
    user_data.create_index([("score", -1), ("username", 1)])
    leaderboard = db["leaderboard"]
    leaderboard.create_index([("username", 1)], unique=True)
    leaderboard.create_index([("score", -1), ("username", 1)])
    return db
