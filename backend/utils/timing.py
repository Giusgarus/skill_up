import datetime
from datetime import timezone as _tz, timedelta, date, datetime as dtime
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

def next_day(day: date | dtime) -> date | dtime:
    """
    Parameters
    ----------
    - day (date | datetime): base day.

    Returns
    -------
    ISO string for the following day.
    """
    if isinstance(day, dtime):
        return day + timedelta(days=1)
    return (dtime.combine(day, dtime.min.time()) + timedelta(days=1)).date()


def weekday(day: date | dtime) -> str:
    """
    Parameters
    ----------
    - day (date | datetime): base day.

    Returns
    -------
    Weekday name (English) for the given day.
    """
    dt = day if isinstance(day, dtime) else dtime.combine(day, dtime.min.time())
    return dt.strftime("%A")

def sort_days(days: list[str], enable_offset_wrt_today: bool = False) -> list[str]:
    all_days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    wanted_days = {day.title() for day in days}
    if not enable_offset_wrt_today:
        return [day for day in all_days if day in wanted_days]
    today_idx = now().weekday() # Monday=0
    ordered: list[str] = []
    for offset in range(7):
        idx = (today_idx + offset) % 7
        day = all_days[idx]
        if day in wanted_days:
            ordered.append(day)
    return ordered