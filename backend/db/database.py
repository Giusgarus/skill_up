from pymongo import MongoClient, PyMongoError
from pymongo.database import Database

def insert(db: Database, record: dict, table_name: str) -> None:
    try:
        result = db[table_name].insert_one(record)
        return {
            "_id": result.inserted_id,
            "error": ""
        }
    except PyMongoError as e:
        return {
            "_id": "",
            "error": str(e)
        }
    
def insert_many(db: Database, records: list[dict], table_name: str) -> None:
    results = []
    for record in records:
        result = insert(db, record, table_name)
        results.append(result)
    return results

def update(db: Database, record: dict, table_name: str) -> None:
    if "_id" not in record.keys():
        return False
    payload = {k: v for k, v in record.items() if k != "_id"}
    try:
        result = db[table_name].update_one({"_id": record["_id"]}, {"$set": payload})
        return {
            "_id": result.upserted_id,
            "error": ""
        }
    except PyMongoError as e:
        return {
            "_id": "",
            "error": str(e)
        }

def update_many(db: Database, records: list[dict], table_name: str) -> None:
    results = []
    for record in records:
        result = update(db, record, table_name)
        results.append(result)
    return results

def query(db: Database, table_name: str, filters: dict = None, projection: dict = None) -> list[dict]:
    try:
        cursor = db[table_name].find(filters or {}, projection=projection) # automatically handles the None cases
        return {
            "data": list(cursor),
            "error": ""
        }
    except PyMongoError as e:
        return {
            "data": [],
            "error": str(e)
        }


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
    leaderboard.create_index([("user_id", 1)], unique=True)
    leaderboard.create_index([("score", -1), ("user_id", 1)])
    return db
