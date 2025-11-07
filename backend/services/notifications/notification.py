import json
import logging
import os
import threading
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import firebase_admin
from fastapi import APIRouter, HTTPException
from firebase_admin import credentials, messaging
from pydantic import BaseModel, Field
from pymongo import MongoClient
import backend.utils.timing as timing

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger("notifications")

MONGO_URI = os.getenv("MONGO_URI", "mongodb://localhost:27017")
MONGO_DB = os.getenv("MONGO_DB", "skillup")

try:
    mongo_client = MongoClient(MONGO_URI)
    mongo_db = mongo_client[MONGO_DB]
    user_collection = mongo_db["users"]
    sessions_collection = mongo_db["sessions"]
    device_tokens_collection = mongo_db["device_tokens"]
except Exception as exc:
    logger.error("Could not connect to MongoDB: %s", exc)
    raise

SERVICE_ACCOUNT_PATH = os.getenv(
    "FIREBASE_SERVICE_ACCOUNT",
    str(Path(__file__).with_name("skillup-9645f-firebase-adminsdk-fbsvc-20eca1ab9c.json")),
)

DEFAULT_TITLE = os.getenv("NOTIFICATION_TITLE", "SkillUp")
DEFAULT_BODY = os.getenv("NOTIFICATION_BODY", "prova")
INTERVAL_SECONDS = max(
    60,
    int(os.getenv("NOTIFICATION_INTERVAL_SECONDS", "300")),
)
FCM_MAX_BATCH = 500

firebase_app: Optional[firebase_admin.App] = None
last_run_lock = threading.Lock()
last_run_summary: Dict[str, Optional[object]] = {
    "last_run": None,
    "result": None,
}
stop_event = threading.Event()
scheduler_started = False


class DeviceRegistration(BaseModel):
    username: str
    session_token: str = Field(alias="session_token")
    device_token: str = Field(alias="device_token", min_length=1)
    platform: str = "android"

    model_config = {"populate_by_name": True}


class ManualNotification(BaseModel):
    body: Optional[str] = None
    title: Optional[str] = None


def _ensure_firebase_app() -> firebase_admin.App:
    global firebase_app
    if firebase_app:
        return firebase_app

    credentials_path = Path(SERVICE_ACCOUNT_PATH)
    if not credentials_path.exists():
        raise RuntimeError(f"Firebase service account file not found at {credentials_path}")

    try:
        with credentials_path.open("r", encoding="utf-8") as handle:
            json.load(handle)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Invalid Firebase credentials file: {exc}") from exc

    cred = credentials.Certificate(str(credentials_path))
    firebase_app = firebase_admin.initialize_app(cred)
    logger.info("Firebase Admin app initialized.")
    return firebase_app


def _verify_session(session_token: str) -> Tuple[str, str]:
    session = sessions_collection.find_one({"token": session_token})
    if not session:
        raise HTTPException(status_code=401, detail="Invalid or expired session token.")
    user_id = session.get("user_id")
    if not user_id:
        raise HTTPException(status_code=401, detail="Session missing user binding.")
    user = user_collection.find_one({"user_id": user_id}, {"username": 1})
    username = user.get("username") if user else None
    if not username:
        raise HTTPException(status_code=404, detail="Bound user no longer exists.")
    return user_id, username


def _chunked(tokens: List[str], size: int) -> List[List[str]]:
    return [tokens[idx: idx + size] for idx in range(0, len(tokens), size)]


def send_broadcast_notification(*, body: Optional[str] = None, title: Optional[str] = None) -> Dict[str, int]:
    _ensure_firebase_app()
    payload_body = (body or DEFAULT_BODY).strip()
    payload_title = (title or DEFAULT_TITLE).strip() or DEFAULT_TITLE

    tokens = [
        doc["device_token"]
        for doc in device_tokens_collection.find({}, {"device_token": 1})
        if doc.get("device_token")
    ]
    if not tokens:
        logger.info("No registered device tokens to notify.")
        return {"sent": 0, "failed": 0, "removed": 0}

    sent = failed = removed = 0
    for batch in _chunked(tokens, FCM_MAX_BATCH):
        message = messaging.MulticastMessage(
            notification=messaging.Notification(
                title=payload_title,
                body=payload_body,
            ),
            data={
                "type": "broadcast",
                "title": payload_title,
                "body": payload_body,
            },
            tokens=batch,
        )
        response = messaging.send_multicast(message, app=firebase_app)
        sent += response.success_count
        failed += response.failure_count
        if response.failure_count:
            for index, resp in enumerate(response.responses):
                if resp.success:
                    continue
                error = getattr(resp, "exception", None)
                code = getattr(error, "code", "") if error else ""
                if code in (
                    "messaging/registration-token-not-registered",
                    "messaging/invalid-registration-token",
                ):
                    device_tokens_collection.delete_one({"device_token": batch[index]})
                    removed += 1
            logger.warning(
                "FCM multicast had failures: %s/%s batch",
                response.failure_count,
                len(batch),
            )

    logger.info(
        "Notification broadcast summary sent=%s failed=%s removed=%s",
        sent,
        failed,
        removed,
    )
    return {"sent": sent, "failed": failed, "removed": removed}


def _scheduler_loop() -> None:
    logger.info(
        "Notification scheduler started with %s seconds interval.",
        INTERVAL_SECONDS,
    )
    # Wait full interval before first send, as requested.
    while not stop_event.wait(INTERVAL_SECONDS):
        try:
            summary = send_broadcast_notification()
            with last_run_lock:
                last_run_summary["last_run"] = timing.now_iso()
                last_run_summary["result"] = summary
        except Exception:  # noqa: BLE001
            logger.exception("Scheduled notification run failed.")


def _start_scheduler_once() -> None:
    global scheduler_started
    if scheduler_started:
        return
    _ensure_firebase_app()
    scheduler_thread = threading.Thread(
        target=_scheduler_loop,
        name="notification-scheduler",
        daemon=True,
    )
    scheduler_thread.start()
    scheduler_started = True