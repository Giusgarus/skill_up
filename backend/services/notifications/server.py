from datetime import datetime
from typing import Dict
from fastapi import APIRouter, HTTPException
import backend.utils.timing as timing
import backend.utils.session as session


router = APIRouter(prefix="/services/notifications", tags=["notifications"])

@router.post("/device", status_code=200)
def register_device(payload: dict) -> Dict[str, str]:
    session = session.get_session(token)
    user_id, username = session.verify_session(payload.session_token)

    canonical_username = payload.username.strip() or username
    if canonical_username != username:
        logger.info(
            "Client username mismatch: client=%s database=%s. Using database value.",
            canonical_username,
            username,
        )

    device_tokens_collection.update_one(
        {"device_token": payload.device_token},
        {
            "$set": {
                "device_token": payload.device_token,
                "user_id": user_id,
                "username": username,
                "platform": payload.platform,
                "updated_at": timing.get_now_timestamp(),
            },
        },
        upsert=True,
    )
    logger.info(
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