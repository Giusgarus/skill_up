from fastapi import APIRouter, Depends, HTTPException, Query
import backend.db.client as client
import backend.utils.session as session

router = APIRouter(prefix="/services/challenges", tags=["challenges"])

@router.get("/plan")
def get_plan(user_id: str = Query(...), date: str = Query(...), db = Depends(client.get_db)):
    if db is None:
        raise HTTPException(status_code=503, detail="DB unavailable")
    pass

@router.post("/task_done", tags=["task_done"])
def task_done(payload: dict) -> dict:
    return {}

@router.post("/prompt", tags=["prompt"])
def get_llm_response(payload: dict) -> dict:
    username = payload.username
    token = payload.token
    prompt = payload.prompt
    valid_token, user_id = session.verify_session(token)
    if not valid_token:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    user_info = client.get_collection("users").find_one({"user_id": user_id})
    if not user_info:
        user_info = {}
    # Qui dovresti implementare la chiamata al server di mos --> HTTP/JSON request
    llm_response = send_json_to_llm_server({
        "prompt": prompt,
        "user_info": user_info
    })
    return {"llm_response": llm_response}