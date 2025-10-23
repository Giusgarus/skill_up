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
    leaderboard = db["leaderboard"]

    users.create_index("username", unique = True)
    sessions.create_index("token", unique = True)
    sessions.create_index("created_at", expireAfterSeconds = 86400)  # your TTL here
    user_data.create_index("user_id", unique = True)
    user_data.create_index([("score", -1), ("username", 1)])
    leaderboard.create_index([("user_id", 1)], unique = True)
    leaderboard.create_index([("score", -1), ("user_id", 1)])

    print("skillup database recreated")

run()