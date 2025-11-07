import datetime
from datetime import timezone as _tz
UTC = _tz.utc

def get_now_timestamp():
    return datetime.datetime.now(UTC)