import json
import logging
import os
import threading
from pathlib import Path
from types import SimpleNamespace
from typing import Dict, List, Optional
import firebase_admin
from firebase_admin import credentials, messaging
from pymongo import ASCENDING
from pymongo.collection import Collection
import backend.utils.timing as timing
import backend.db.database as db

SERVICE_ACCOUNT_PATH = os.getenv(
    "FIREBASE_SERVICE_ACCOUNT",
    str(Path(__file__).with_name("skillup-da594-firebase-adminsdk-fbsvc-ee68e7845d.json")),
)
DEFAULT_TITLE = os.getenv("NOTIFICATION_TITLE", "SkillUp")
DEFAULT_BODY_TEMPLATE = os.getenv(
    "NOTIFICATION_BODY",
    "Hi {name}, you're doing great, keep it up.",
)
INTERVAL_SECONDS = 60
FCM_MAX_BATCH = 500
_has_send_multicast = hasattr(messaging, "send_multicast")
_has_send_all = hasattr(messaging, "send_all")
_has_send_each = hasattr(messaging, "send_each")

firebase_app: Optional[firebase_admin.App] = None
last_run_lock = threading.Lock()
last_run_summary: Dict[str, Optional[object]] = {
    "last_run": None,
    "result": None,
}
stop_event = threading.Event()
scheduler_started = False

def get_logger():
    logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
    return logging.getLogger("Notification_Server")

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
    get_logger().info("Firebase Admin app initialized.")
    return firebase_app


def _chunked(tokens: List[str], size: int) -> List[List[str]]:
    return [tokens[idx: idx + size] for idx in range(0, len(tokens), size)]


def _load_user_profiles(user_ids: List[str]) -> Dict[str, dict]:
    if not user_ids:
        return {}
    filters = {"user_id": {"$in": user_ids}}
    projection = {
        "_id": False,
        "user_id": True,
        "username": True,
        "name": True,
        "surname": True,
        "data": True,
    }
    try:
        documents = db.find_many("users", filters=filters, projection=projection)
    except RuntimeError:
        return {}
    return {
        doc["user_id"]: doc
        for doc in documents
        if doc.get("user_id")
    }


def _resolve_user_display_name(user_doc: Optional[dict], fallback_username: Optional[str]) -> str:
    fallback = (fallback_username or "").strip() or "utente SkillUp"
    if not user_doc:
        return fallback
    profile_data = user_doc.get("data") or {}
    first_name = (user_doc.get("name") or profile_data.get("name") or "").strip()
    last_name = (user_doc.get("surname") or profile_data.get("surname") or "").strip()
    if first_name and last_name:
        return f"{first_name} {last_name}"
    if first_name:
        return first_name
    if last_name:
        return last_name
    return user_doc.get("username", fallback) or fallback


def _default_personalized_body(name: str) -> str:
    template = DEFAULT_BODY_TEMPLATE or "Hi {name}, you're doing great, keep it up"
    safe_name = name.strip() or "utente SkillUp"
    try:
        return template.format(name=safe_name)
    except (KeyError, IndexError, ValueError):
        return template.replace("{name}", safe_name)


def send_broadcast_notification(*, body: Optional[str] = None, title: Optional[str] = None) -> Dict[str, int]:
    app = _ensure_firebase_app()
    payload_title = (title or DEFAULT_TITLE).strip() or DEFAULT_TITLE

    device_tokens_collection = (db.connect_to_db())["device_tokens"]
    cursor = device_tokens_collection.find({}, {"device_token": 1, "user_id": 1, "username": 1})
    tokens_by_user: Dict[str, List[str]] = {}
    username_by_user: Dict[str, str] = {}
    for doc in cursor:
        token = (doc or {}).get("device_token")
        user_id = (doc or {}).get("user_id")
        if not token or not user_id:
            continue
        tokens_by_user.setdefault(user_id, []).append(token)
        username = (doc or {}).get("username")
        if username and user_id not in username_by_user:
            username_by_user[user_id] = username
    if not tokens_by_user:
        get_logger().info("No registered device tokens to notify.")
        return {"sent": 0, "failed": 0, "removed": 0}

    total_sent = total_failed = total_removed = 0
    if body is not None:
        payload_body = body.strip() or _default_personalized_body("utente SkillUp")
        all_tokens = [token for tokens in tokens_by_user.values() for token in tokens]
        sent, failed, removed = _dispatch_notification(
            all_tokens,
            payload_title,
            payload_body,
            app,
            device_tokens_collection,
        )
        total_sent += sent
        total_failed += failed
        total_removed += removed
    else:
        user_profiles = _load_user_profiles(list(tokens_by_user.keys()))
        for user_id, tokens in tokens_by_user.items():
            display_name = _resolve_user_display_name(user_profiles.get(user_id), username_by_user.get(user_id))
            personalized_body = _default_personalized_body(display_name)
            sent, failed, removed = _dispatch_notification(
                tokens,
                payload_title,
                personalized_body,
                app,
                device_tokens_collection,
            )
            total_sent += sent
            total_failed += failed
            total_removed += removed

    get_logger().info(
        "Notification broadcast summary sent=%s failed=%s removed=%s",
        total_sent,
        total_failed,
        total_removed,
    )
    return {"sent": total_sent, "failed": total_failed, "removed": total_removed}


def _dispatch_notification(
    tokens: List[str],
    title: str,
    body: str,
    app: firebase_admin.App,
    collection: Collection,
) -> tuple[int, int, int]:
    if not tokens:
        return (0, 0, 0)
    notification_payload = messaging.Notification(
        title=title,
        body=body,
    )
    data_payload = {
        "type": "broadcast",
        "title": title,
        "body": body,
    }
    sent = failed = removed = 0
    for batch in _chunked(tokens, FCM_MAX_BATCH):
        response = _send_batch(batch, notification_payload, data_payload, app)
        sent += response.success_count
        failed += response.failure_count
        removed += _process_batch_response(batch, response, collection)
    return (sent, failed, removed)


def _process_batch_response(
    token_batch: List[str],
    response,
    collection: Collection,
) -> int:
    if not getattr(response, "failure_count", 0):
        return 0
    removed = 0
    responses = getattr(response, "responses", []) or []
    for resp, token in zip(responses, token_batch):
        if getattr(resp, "success", False):
            continue
        error = getattr(resp, "exception", None)
        code = getattr(error, "code", "") if error else ""
        if code in (
            "messaging/registration-token-not-registered",
            "messaging/invalid-registration-token",
        ):
            collection.delete_one({"device_token": token})
            removed += 1
    get_logger().warning(
        "FCM multicast had failures: %s/%s batch",
        getattr(response, "failure_count", 0),
        len(token_batch),
    )
    return removed


def _send_batch(
    token_batch: List[str],
    notification_payload: messaging.Notification,
    data_payload: Dict[str, str],
    app: firebase_admin.App,
):
    if _has_send_multicast:
        message = messaging.MulticastMessage(
            notification=notification_payload,
            data=data_payload,
            tokens=token_batch,
        )
        return messaging.send_multicast(message, app=app)

    messages = [
        messaging.Message(
            notification=notification_payload,
            data=data_payload,
            token=token,
        )
        for token in token_batch
    ]
    if _has_send_all:
        return messaging.send_all(messages, app=app)
    if _has_send_each:
        return messaging.send_each(messages, app=app)
    return _send_messages_individually(messages, app)


def _send_messages_individually(
    messages: List[messaging.Message],
    app: firebase_admin.App,
):
    responses = []
    for message in messages:
        try:
            messaging.send(message, app=app)
            responses.append(SimpleNamespace(success=True, exception=None))
        except Exception as exc:  # noqa: BLE001
            responses.append(SimpleNamespace(success=False, exception=exc))
    success = sum(1 for resp in responses if resp.success)
    failure = len(responses) - success
    return SimpleNamespace(
        success_count=success,
        failure_count=failure,
        responses=responses,
    )


def _scheduler_loop() -> None:
    get_logger().info(
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
            get_logger().exception("Scheduled notification run failed.")


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


def start_scheduler() -> None:
    _start_scheduler_once()
