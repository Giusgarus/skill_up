from datetime import datetime
from typing import Dict
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
import notification as notify
import backend.utils.timing as timing
import backend.utils.session as session
import backend.db.database as db


class DeviceRegistration(BaseModel):
    user_id: str
    username: str
    platform: str = "android"
    # questi campi servono davvero? che differenza di logica c'è tra il token del device e quello della sessione?
    session_token: str
    device_token: str
    model_config: dict = {"populate_by_name": True}

class ManualNotification(BaseModel):
    body: str = None
    title: str = None


router = APIRouter(prefix="/services/notifications", tags=["notifications"])

@router.post("/device", status_code=200)
def register_device(payload: DeviceRegistration) -> Dict[str, str]:
    token = session.generate_session(payload["user_id"])
    ok, user_id = session.verify_session(token)
    if not ok:
        raise HTTPException(status_code=400, detail="Invalid or missing token used to generate the session")
    if not user_id:
        raise HTTPException(status_code=401, detail="Session missing user binding")
    username = db.find_one(
        table_name="users",
        filters={"user_id": user_id},
        projection={"_id": False, "username": True}
    )
    if not username:
        raise HTTPException(status_code=404, detail="Bound user no longer exists.")
    given_username = payload.username.strip() or username
    if given_username != username:
        notify.get_logger().info(
            "Client username mismatch: client=%s database=%s. Using database value.",
            given_username,
            username,
        )
    # l'insert va fatto in session o serve anche una tabella "devices"? oppure vanno aggiunti campi alla tabella "sessions"?
    db.insert(
        table_name="sessions",
        record={
            "user_id": user_id,
            "device_token": payload.device_token, # I CAMPI INSERITI NON VANNO BENE, DA CAPIRE DI COSA FARE LA INSERT
            "user_id": payload["user_id"],
            "username": username,
            "updated_at": timing.now(),
        },
    )
    notify.get_logger().info(
        "Registered device token for user %s (%s).",
        username,
        payload.platform,
    )
    return {"status": "registered"}


@router.post("/send-now", status_code=200)
def send_now(payload: dict) -> Dict[str, int]:
    summary = send_broadcast_notification(body=payload.body, title=payload.title)
    with last_run_lock:
        last_run_summary["last_run"] = datetime.now(UTC).isoformat()
        last_run_summary["result"] = summary
    return summary


@router.get("/status")
def scheduler_status() -> Dict[str, object]:
    token_count = device_tokens_collection.estimated_document_count()
    with last_run_lock:
        last_run = last_run_summary["last_run"]
        result = last_run_summary["result"]
    return {
        "interval_seconds": INTERVAL_SECONDS,
        "last_run": last_run,
        "last_result": result,
        "registered_tokens": token_count,
        "scheduler_running": scheduler_started and not stop_event.is_set(),
    }