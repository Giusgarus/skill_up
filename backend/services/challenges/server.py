from fastapi import APIRouter, Depends, HTTPException, Query, status
import backend.db.database as db
import backend.utils.session as session
import backend.utils.timing as utils
from pydantic import BaseModel, StringConstraints, constr
from typing import Annotated, Any, Set
from pymongo.errors import PyMongoError
from pymongo import ReturnDocument

MIN_HEAP_K_LEADER = 10
ALLOWED_DATA_FIELDS: Set[str] = {"score", "name", "surname", "height", "weight", "sex", "info1", "info2", "info3", "info4"}
MIN_LEN_ADF = 1
MAX_LEN_ADF = 500


RecordStr = Annotated[
    str,
    StringConstraints(
        strip_whitespace = True,
        min_length = MIN_LEN_ADF,
        max_length = MAX_LEN_ADF,
        pattern = r"^[A-Za-z0-9_]+$",
    ),
]
class UpdateUserBody(BaseModel):
    token: str 
    attribute: str
    record: RecordStr

class SetTaskDone(BaseModel):
    token: str
    task_id: int

class GeneratePlan(BaseModel):
    token: str
    plan: str

router = APIRouter(prefix="/services/challenges", tags=["challenges"])

@router.post("/task_done", status_code = 201)
def task_done(payload: SetTaskDone) -> dict:
    ok, user_id = session.verify_session(payload.token)
    if not ok or not user_id:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    task_id = payload.task_id
    if not task_id:
        raise HTTPException(status_code = 402, detail = "Invalid Task ID")
    # Manca l'api per gli update che non sono setter ma sono più complessi, vedi te come implementarlo e se implementarlo
    # Qui lo faccio in maniera diretta senza la tua API
    proj_task = db.client.get_collection("tasks").find_one_and_update({"task_id" : task_id, "user_id" : user_id},{"$set": {"completed_at": utils.now()}}, projection = {"_id" : False, "score" : True}, return_document = ReturnDocument.AFTER)
    score = proj_task["score"] if proj_task else None
    # is None diverso da not, se è 0 il not è vero perché è false, ma non è None
    if score is None:
        raise HTTPException(status_code = 403, detail = "Invalid score in Task ID")
    proj_user_data = db.client.get_collection("users").find_one_and_update({"user_id": user_id}, {"$inc": {"n_tasks_done": 1, "data.score": score}}, projection = {"_id": False, "username": True, "data.score": True}, return_document = ReturnDocument.AFTER)
    new_score = proj_user_data["data"]["score"] if proj_user_data else None
    username = proj_user_data["username"] if proj_user_data else None
    if new_score is None or not username:
        raise HTTPException(status_code = 403, detail = "Invalid projection after updating user")
    # Ora aggiorno la leaderboard
    db.client.get_collection("leaderboard").update_one( {"_id": "topK"},
        {
            "$pull": {"items": {"username": username}},
            "$push": {
                "items": {
                    "$each": [{"username": username, "score": new_score}],
                    "$sort": {"score": -1, "username": 1},
                    "$slice": MIN_HEAP_K_LEADER
                }
            }
        },
        upsert = True)
    return {"status" : True}

@router.post("/set", status_code = 201)
def update_user(payload: UpdateUserBody):
    valid_token, user_id = session.verify_session(payload.token)
    if not valid_token:
        raise HTTPException(status_code = 400, detail = "Invalid or missing token")
    if payload.attribute not in ALLOWED_DATA_FIELDS:
        raise HTTPException(status_code = 401, detail = "Unsupported attribute")
    try:
        up_status = db.update("users", {"user_id" : user_id, f"data.{payload.attribute}": payload.record})
        if up_status.matched_count == 0:
            raise HTTPException(status_code = 402, detail = "User not found")
    except PyMongoError: 
        raise HTTPException(status_code = 403, detail = "Database error")
    return {"updated": True, "new_record": payload.record}

@router.get("/prompt", status_code = 201)
def get_llm_response(payload: GeneratePlan) -> dict:
    token = payload.token
    prompt = payload.plan
    valid_token, user_id = session.verify_session(token)
    if not valid_token:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    results = db.find_one(table_name = "users", filters = {"user_id": user_id}, projection = {"_id": False, "data": True})
    if results == None:
        raise HTTPException(status_code = 402, detail = "Invalid user")
    user_info = results["data"] if results else None
    if not user_info:
        user_info = {}
    # Qui dovresti implementare la chiamata al server di mos --> HTTP/JSON request
    llm_response = send_json_to_llm_server({
        "prompt": prompt,
        "user_info": user_info
    })
    # Controlla risposta e aggiorna tutti i campi necessari 
    # ...
    return {}
