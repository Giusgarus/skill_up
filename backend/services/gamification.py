import backend.db.client as client

LEADERBOARD_K = 10

def leaderboard_update(user_id: str, score: int, K: int = LEADERBOARD_K) -> None:
    '''
    Update the leaderborad with the K users with the higher score.
    '''
    leaderboard_collection = client.get_collection("leaderboard")
    leaderboard_collection.update_one({"user_id": user_id}, {"$set": {"score": int(score)}}, upsert = True)
    total = leaderboard_collection.estimated_document_count()
    if total <= K:
        return
    keep_docs = list(leaderboard_collection.find({}, {"user_id": 1}).sort([("score", -1), ("user_id", 1)]).limit(K))
    keep_ids = [d["user_id"] for d in keep_docs]
    leaderboard_collection.delete_many({"user_id": {"$nin": keep_ids}})