from pymongo import MongoClient, PyMongoError
from typing import Optional
from pymongo.database import Database
from pymongo.collection import Collection
from pymongo import ASCENDING, DESCENDING
import db.client as client
from pymongo.collection import Collection
from pymongo import ASCENDING, DESCENDING
import utility

def connect_to_db() -> Database:
    if not client.ping():
        client.connect()
    return client.get_db()

def insert(table_name: str, record: dict) -> dict:
    db = connect_to_db()
    if not utility.check_primary_keys(table_name, record):
        raise RuntimeError(f"The primary keys {utility.table_primary_keys_dict[table_name]} of '{table_name}' are required in the record field")
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
    if not utility.check_primary_keys(table_name, record):
        raise RuntimeError(f"The primary keys {utility.table_primary_keys_dict[table_name]} of '{table_name}' are required in the record field")
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

def find_one(table_name: str, filters: dict = {}, projection: dict = None) -> list:
    db = connect_to_db()
    try:
        cursor = db[table_name].find_one(filter = filters, projection = projection) # automatically handles the None cases
        return cursor
    except PyMongoError as e:
        raise RuntimeError(e)

def find_many(table_name: str, filters: dict = {}, projection: dict = None) -> list[dict]:
    db = connect_to_db()
    collection = db[table_name]
    assert isinstance(collection, Collection) # assures that db[table_name] is able to call the find method
    try:
        cursor = db[table_name].find(filter = filters, projection = projection)
        return list(cursor)
    except PyMongoError as e:
        raise RuntimeError(e)

def create_indexes(db: Optional[Database]) -> None:
    if db is None:
        return
    db["users"].create_index([("user_id", ASCENDING)], unique=True, name="users_index1")
    db["users"].create_index([("username", ASCENDING)], unique=True, name="users_index2")
    db["tasks"].create_index([("user_id", ASCENDING), ("task_id", ASCENDING)], unique=True, name="tasks_index")
    db["sessions"].create_index([("token", ASCENDING)], unique=True, name="sessions_index")
    db["leaderboard"].create_index([("username", ASCENDING)], unique = True, name="leaderboard_index")
    db["leaderboard"].create_index([("score", DESCENDING), ("username", ASCENDING)])

def create(url: str = "mongodb://localhost:27017", enable_drop: bool = False):
    '''
    Creates and establishes the connection with the DB.

    Parameters:
    - url (str):
    - enable_drop (bool): if True, the skillup DB is dropped and recreated (in this case all the data will be lost).

    Returns: the skillup database created.
    '''
    client = MongoClient(url, serverSelectionTimeoutMS = 5000)
    client.admin.command("ping")
    # 1) Drop the database
    if enable_drop:
        client.drop_database("skillup")
    # 2) Creation of the tables and the indexes
    db = create_indexes(client["skillup"])
    return db
