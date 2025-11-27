from __future__ import annotations
from typing import Dict, Optional
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, ConfigDict, Field
from backend.services.notifications import notification as notify
import backend.db.database as db
import backend.utils.session as session
import backend.utils.timing as timing

SUPPORTED_PLATFORMS = {"android", "ios", "macos", "windows", "web"}
DEFAULT_PLATFORM = "unknown"
router = APIRouter(prefix="/services/notifications", tags=["Notifications"])
LOGGER = notify.get_logger()


class DeviceRegistration(BaseModel):
    username: str = Field(..., description="Username that owns the device.")
    platform: str = Field("android", description="Device platform (android, ios, web, etc.).")
    session_token: str = Field(..., description="User session token.")
    device_token: str = Field(..., description="Push token provided by the notification service.")

class ManualNotification(BaseModel):
    title: Optional[str] = Field(None, description="Optional title for the notification.")
    body: Optional[str] = Field(None, description="Notification body; if omitted it is personalized per user.")


class DeviceRegistrationResponse(BaseModel):
    status: str = Field(..., description="Status of the device registration request.")
    platform: str = Field(..., description="Platform stored for the device.")


class NotificationSummary(BaseModel):
    model_config = ConfigDict(extra="allow")
    sent: int = Field(..., description="Number of notifications sent successfully.")
    failed: int = Field(..., description="Number of failed sends.")
    removed: int = Field(..., description="Tokens removed because they were invalid.")


class ErrorResponse(BaseModel):
    detail: str = Field(..., description="Error detail.")


@router.on_event("startup")
def _start_scheduler() -> None:
    try:
        notify.start_scheduler()
    except Exception as exc:  # noqa: BLE001
        LOGGER.exception("Failed to start notification scheduler: %s", exc)


@router.post(
    "/device",
    status_code=200,
    summary="Register a notification device",
    description=(
        "Associates a push device token to the authenticated user.  \n"
        "- Validates the session token.  \n"
        "- Normalizes platform and username.  \n"
        "- Saves or updates the device registration."
    ),
    operation_id="registerDeviceToken",
    response_model=DeviceRegistrationResponse,
    responses={
        400: {"model": ErrorResponse, "description": "Username missing."},
        401: {"model": ErrorResponse, "description": "Session token missing."},
        402: {"model": ErrorResponse, "description": "Device token missing."},
        403: {"model": ErrorResponse, "description": "Invalid or missing session token."},
        404: {"model": ErrorResponse, "description": "User not found."},
    },
)
def register_device(payload: DeviceRegistration) -> Dict[str, str]:
    username = payload.username.strip()
    platform = (payload.platform or DEFAULT_PLATFORM).strip().lower() or DEFAULT_PLATFORM
    session_token = payload.session_token.strip()
    device_token = payload.device_token.strip()
    if not username:
        raise HTTPException(status_code=400, detail="Username is required.")
    if not session_token:
        raise HTTPException(status_code=401, detail="Session token required.")
    if not device_token:
        raise HTTPException(status_code=402, detail="Device token required.")
    ok, session_user_id = session.verify_session(session_token)
    if not ok or not session_user_id:
        raise HTTPException(status_code=403, detail="Invalid or missing session token.")
    user_id = session_user_id
    user_doc = db.find_one(
        table_name="users",
        filters={"user_id": user_id},
        projection={"_id": False, "username": True},
    )
    if not user_doc:
        raise HTTPException(status_code=404, detail="User not found.")
    canonical_username = user_doc["username"]
    if canonical_username != username:
        LOGGER.info(
            "Username mismatch during device registration: client=%s db=%s",
            username,
            canonical_username,
        )
    if platform not in SUPPORTED_PLATFORMS:
        LOGGER.warning("Unsupported notification platform '%s'. Storing as '%s'.", platform, DEFAULT_PLATFORM)
        platform = DEFAULT_PLATFORM
    now = timing.now()
    res = db.update_one("device_tokens", keys_dict = {"device_token": device_token}, values_dict = {"$set": {"user_id": user_id,"username": canonical_username,"platform": platform,"session_token": session_token,"updated_at": now,},"$setOnInsert": {"created_at": now},}, upsert = True)
    LOGGER.info(
        "Registered %s device token for user %s (upserted=%s).",
        platform,
        canonical_username,
        bool(res.upserted_id),
    )
    return {"status": "registered", "platform": platform}

@router.post(
    "/send-now",
    status_code=200,
    summary="Send notifications now",
    description=(
        "Sends push notifications immediately to all registered devices.  \n"
        "If `body` is omitted, a personalized message is generated per user."
    ),
    operation_id="sendBroadcastNotification",
    response_model=NotificationSummary,
)
def send_now(payload: ManualNotification) -> Dict[str, int]:
    summary = notify.send_broadcast_notification(body=payload.body, title=payload.title)
    with notify.last_run_lock:
        notify.last_run_summary["last_run"] = timing.now_iso()
        notify.last_run_summary["result"] = summary
    return summary


#@router.get("/status")
#def scheduler_status() -> Dict[str, object]:
    #collection = _get_device_tokens_collection()
    #token_count = collection.estimated_document_count()
    #with notify.last_run_lock:
    #    last_run = notify.last_run_summary["last_run"]
    #    result = notify.last_run_summary["result"]
    #return {
    #    "interval_seconds": notify.INTERVAL_SECONDS,
    #    "last_run": last_run,
    #    "last_result": result,
    #    "registered_tokens": token_count,
    #    "scheduler_running": notify.scheduler_started and not notify.stop_event.is_set(),
    #}
