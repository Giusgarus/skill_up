import datetime
from datetime import timezone as _tz
UTC = _tz.utc

def now():
    return datetime.datetime.now(UTC)

def now_iso():
    return datetime.datetime.now(UTC).isoformat()

def from_iso_to_datetime(iso_str: str) -> datetime.datetime:
    return datetime.datetime.fromisoformat(iso_str).astimezone(UTC)

def get_last_date(dates: list[str]) -> str:
    if not dates:
        raise ValueError("The dates list is empty")
    date_objs = [from_iso_to_datetime(date_str) for date_str in dates]
    last_date = max(date_objs)
    return last_date.isoformat()