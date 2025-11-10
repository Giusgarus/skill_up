from typing import Optional
from pymongo import ASCENDING, DESCENDING, MongoClient
from pymongo.collection import Collection
from pymongo.database import Database
from pymongo.errors import PyMongoError
from backend.db import client, utility

def _ensure_index(collection: Collection, keys: list[tuple[str, int]], **kwargs) -> None:
    existing = collection.index_information()
    for info in existing.values():
        if info.get("key") == keys:
            return
    collection.create_index(keys, **kwargs)

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

def update_one(table_name: str, keys_dict: dict, values_dict: dict) -> dict:
    db = connect_to_db()
    if not utility.check_primary_keys(table_name, keys_dict):
        raise RuntimeError(f"The primary keys {utility.table_primary_keys_dict[table_name]} of '{table_name}' are required in the record field")
    try:
        return db[table_name].update_one(keys_dict, values_dict)
    except PyMongoError as e:
        raise RuntimeError(e)

def update_many(table_name: str, records: list[dict]) -> list[dict]:
    results = []
    # Check of presence of the keys for each record
    keys_dict = {}
    for i, record in enumerate(records):
        keys_dict[i] = {}
        for key in utility.table_primary_keys_dict[table_name]:
            if key not in record.keys():
                raise RuntimeError(f"The primary keys {utility.table_primary_keys_dict[table_name]} of '{table_name}' are required in the records field")
            keys_dict[i][key] = record[key]
            del record[key]
    # Update of each record
    for i, record in enumerate(records):
        result = update_one(table_name, keys_dict[i], record)
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

def find_one_and_update(table_name: str, values_dict: dict, return_policy, keys_dict: dict = {}, projection: dict = None) -> list:
    db = connect_to_db()
    try:
        proj = db[table_name].find_one_and_update(filter = keys_dict, update = values_dict, projection = projection, return_document = return_policy)
        return proj
    except PyMongoError as e:
        raise RuntimeError(e)

def create_indexes(db: Optional[Database]) -> None:
    if db is None:
        return
    users = db["users"]
    tasks = db["tasks"]
    sessions = db["sessions"]
    leaderboard = db["leaderboard"]

    _ensure_index(users, [("user_id", ASCENDING)], unique=True, name="users_index1")
    _ensure_index(users, [("username", ASCENDING)], unique=True, name="users_index2")
    _ensure_index(tasks, [("user_id", ASCENDING), ("task_id", ASCENDING)], unique=True, name="tasks_index")
    _ensure_index(sessions, [("token", ASCENDING)], unique=True, name="sessions_index")
    _ensure_index(leaderboard, [("_id", ASCENDING)], unique=True, name="leaderboard_index")

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
