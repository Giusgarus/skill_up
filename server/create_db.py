from pymongo import MongoClient

def run():
    client = MongoClient("mongodb://localhost:27017", serverSelectionTimeoutMS = 5000)
    client.admin.command("ping")  # sanity check

    # 1) Drop the database
    client.drop_database("skillup")

    # 2) Recreate collections and indexes
    db = client["skillup"]
    users = db["users"]
    sessions = db["sessions"]
    user_data = db["user_data"]

    users.create_index("username", unique = True)
    sessions.create_index("token", unique = True)
    sessions.create_index("created_at", expireAfterSeconds = 86400)  # your TTL here

    print("skillup recreated ✔")

run()