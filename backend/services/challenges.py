from fastapi import APIRouter, Depends, HTTPException, Query
import backend.db.database as db
import backend.utils.session as session

router = APIRouter(prefix="/services/challenges", tags=["challenges"])

@router.get("/plan", status_code=201)
def get_plan(user_id: str = Query(...), date: str = Query(...), db = Depends(db.connect_to_db)):
    if db is None:
        raise HTTPException(status_code=503, detail="DB unavailable")
    pass

@router.post("/task_done", status_code=201)
def task_done(payload: dict) -> dict:
    token = payload["token"]
    now_timestamp = session.get_now_timestamp()
    task_id = payload["task_id"]
    user_id = payload["user_id"]
    cursor = db.find(
        table_name="tasks",
        filters={"task_id": task_id, "user_id": user_id}
    )
    record = cursor[0]
    # Modifica il task e reinseriscilo nel DB (fai una update sul campo task_done o quello che e')
    return {}

@router.post("/set", status_code=201)
def update_user(payload: dict):
    attribute = payload["attribute"]
    record = payload["record"]
    # fare update

@router.get("/prompt", status_code=201)
def get_llm_response(payload: dict) -> dict:
    username = payload.username
    token = payload.token
    prompt = payload.prompt
    valid_token, user_id = session.verify_session(token)
    if not valid_token:
        raise HTTPException(status_code = 401, detail = "Invalid or missing token")
    results = db.find(
        table_name="user_data",
        filters={"user_id": user_id}
    )
    user_info = results["data"][0]
    if not user_info:
        user_info = {}
    # Qui dovresti implementare la chiamata al server di mos --> HTTP/JSON request
    llm_response = send_json_to_llm_server({
        "prompt": prompt,
        "user_info": user_info
    })
    return {"llm_response": llm_response}