import datetime
from datetime import timezone as _tz
UTC = _tz.utc

def now():
    return datetime.datetime.now(UTC)

def now_iso():
    return datetime.datetime.now(UTC).isoformat()