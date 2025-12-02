import json
import os
import logging
from pathlib import Path
from typing import Literal, Tuple, Dict, Any
import requests
from requests.adapters import HTTPAdapter, Retry
from backend.utils import timing

logger = logging.getLogger("llm_interaction")


# ==============================
#         Load Variables
# ==============================
CONFIG_PATH = Path(__file__).resolve().parents[1] / "utils" / "env.json"
with CONFIG_PATH.open("r", encoding="utf-8") as f:
    _cfg = json.load(f)

LLM_SERVER_URL = _cfg.get("LLM_SERVER_URL")
LLM_SERVICE_TOKEN = _cfg.get("LLM_SERVICE_TOKEN")
LLM_TIMEOUT = _cfg.get("LLM_TIMEOUT")
LLM_MAX_RETRIES = _cfg.get("LLM_MAX_RETRIES")



# ==============================
#          Functions
# ==============================
def get_session(retries: int = LLM_MAX_RETRIES, backoff_factor: float = 0.3) -> requests.Session:
    """Return a requests session configured with retry policy."""
    session = requests.Session()
    retry = Retry(
        total=retries,
        read=retries,
        connect=retries,
        backoff_factor=backoff_factor,
        status_forcelist=(429, 502, 503, 504),
        allowed_methods=frozenset(["POST", "GET", "PUT", "DELETE", "OPTIONS"]),
    )
    adapter = HTTPAdapter(max_retries=retry)
    session.mount("https://", adapter)
    session.mount("http://", adapter)
    return session


def validate_challenges(resp: Dict[str, Any]) -> Tuple[bool, str]:
    """
    Parameters
    ----------
    - resp (dict): the expected structure is the following (with date string in ISO format, 
    use the backend.utils.timing library to parse/format):

        {
            "prompt": str, # the used prompt to get this tasks
            "n_tasks": int,
            "tasks": {
                "date1":  {"title": str, "description": str, "difficulty": str},
                "date2":  {"title": str, "description": str, "difficulty": str},
                ...
            }
        }

    Returns
    -------
    (is_valid, error_message_or_empty)
    """
    if not isinstance(resp, dict):
        return False, "Response is not a JSON object"

    # 1. Validate Top Level Keys
    if "tasks" not in resp or not isinstance(resp["tasks"], list):
        return False, "Missing or invalid 'tasks'"
    if "n_tasks" not in resp or not isinstance(resp["n_tasks"], int):
        return False, "Missing or invalid 'n_tasks'"
    if len(resp["tasks"]) == 0:
        return False, "Challenge list is empty"

    # 2. Validate Individual Challenge Objects
    required_item_keys = ["title", "description", "difficulty"]
    for i, key_item in enumerate(dict(resp["tasks"]).items()):
        key, item = key_item
        # Check if the key is a date string
        try:
            timing.from_iso_to_datetime(key)
        except Exception:
            return False, f"Challenge #{i+1}: Key '{key}' is not a valid ISO date string"
        # Check Keys
        for k in required_item_keys:
            if k not in item:
                return False, f"Challenge #{i+1} missing key: {k}"
        # Check Types
        if not isinstance(item["title"], str) or not isinstance(item["description"], str):
            return False, f"Challenge #{i+1}: Title/description must be strings"
        if not isinstance(item["duration_minutes"], (int, float)):
            return False, f"Challenge #{i+1}: duration_minutes must be numeric"
        # Check Logic
        if item["difficulty"] not in ("Easy", "Medium", "Hard"):
            return False, f"Challenge #{i+1}: Invalid difficulty"

    return True, ""


def communicate(url: str, body: dict, headers: dict):
    '''
    Returns
    -------
    - {"status": False, "error": "..."} --> if an error occurred.
    - {"status": True, "result": {...}} --> if the call was successful. The expected structure of 
    the 'result' field depends by the type of request done.
    '''

    # 1. Create session
    session = get_session(LLM_MAX_RETRIES, backoff_factor=0.3)

    # 2. Send request
    try:
        logger.info("Calling LLM server %s (goal len=%d)", url, len(body["goal"]))
        resp = session.post(url, json=body, timeout=LLM_TIMEOUT, headers=headers)
    except requests.RequestException as e:
        logger.error("Error contacting LLM server: %s", e, exc_info=True)
        return {"status": False, "error": f"Server unreachable: {str(e)}"}
    
    # 3. Handle response
    if resp.status_code != 200:
        content_snippet = (resp.text[:500] + "...") if resp.text else ""
        logger.warning("LLM server returned status %d: %s", resp.status_code, content_snippet)
        try:
            parsed = resp.json()
            detail_msg = parsed.get("message") or parsed.get("detail") or ""
        except Exception:
            detail_msg = ""
        msg_suffix = f": {detail_msg}" if detail_msg else ""
        return {"status": False, "error": f"LLM server error ({resp.status_code}){msg_suffix}"}
    try:
        result = resp.json()
    except ValueError:
        logger.error("LLM server returned non-json response: %s", resp.text[:500])
        return {"status": False, "error": "Invalid JSON from LLM server"}
    
    return {"status": True, "result": result}


def get_llm_retask_response(payload: Dict[str, Any]) -> Dict[str, Any]:
    """
    Parameters
    ----------
    - payload (dict): the expected keys are:
        - "goal" (str): the goal written by the user,
        - "level" (int): the level of the user for that plan,
        - "history" (list): history of the previous prompts/responses for that user (with the last prompt/response in the last position)

            [
                {
                    "prompt": str,
                    "response": str
                },
                ...
            ]

        - "user_info" (dict): the dictionary with all the fields in the users collection.

    Returns
    -------
    - {"status": False, "error": "..."} --> if an error occurred.
    - {"status": True, "result": {...}} --> if the call was successful. The expected structure of 
    the 'result' field is the following (with date string in ISO format, use the backend.utils.timing 
    library to parse/format):

        {
            "prompt": str, # the used prompt to get this tasks
            "response": str, # the response got from the LLM
            "tasks": {
                "date1":  {"title": str, "description": str, "difficulty": str},
                "date2":  {"title": str, "description": str, "difficulty": str},
                ...
            }
        }

    """
    url = LLM_SERVER_URL.rstrip("/") + "/replan-task"

    # 1. Data extraction
    goal = str(payload.get("goal")).strip() if payload.get("goal") else ""
    goal = goal[:100]  # align with LLM contract
    level = str(payload.get("level", "beginner")).lower()
    previous_task = payload.get("previous_task") or {}
    llm_response = payload.get("llm_response") or ""

    if not isinstance(previous_task, str):
        try:
            previous_task = json.dumps(previous_task)
        except Exception:  # pragma: no cover - best effort
            previous_task = str(previous_task)

    if isinstance(llm_response, (dict, list)):
        try:
            llm_response = json.dumps(llm_response)
        except Exception:  # pragma: no cover - defensive path
            llm_response = str(llm_response)
    # Trim llm_response to stay within the LLM service request limits (Pydantic max_length=2500)
    if isinstance(llm_response, str) and len(llm_response) > 2400:
        llm_response = llm_response[:2400]

    # 2. Prepare Body --> ensure we don't convert None to "None" string.
    body = {
        "goal": goal,
        "level": level,
        "previous_task": previous_task,
        "llm_response": llm_response,
        "modification_reason": payload.get("modification_reason"),
    }

    # 3. Prepare Headers --> include also the authentication token if available.
    headers = {"Content-Type": "application/json"}
    if LLM_SERVICE_TOKEN:
        headers["Authorization"] = f"Bearer {LLM_SERVICE_TOKEN}"

    # 4. Communication with the LLM server
    response = communicate(url, body, headers)
    if not response["status"] and "error" in response:
        return {"status": False, "error": f"LLM server: {response.get('error')}"}
    result = response.get("result", {})
    if isinstance(result, dict) and ("error" in result or "detail" in result):
        msg = result.get("error") or result.get("detail") or "LLM server reported an error"
        return {"status": False, "error": f"LLM server: {msg}"}
    
    return {"status": True, "result": result}


def get_llm_response(payload: Dict[str, Any]) -> Dict[str, Any]:
    """
    Parameters
    ----------
    - payload (dict): the expected keys are:
        - "goal" (str): the goal written by the user,
        - "level" (int): the level of the user for that plan,
        - "history" (list): history of the previous prompts/responses for that user (with the last prompt/response in the last position)

            [
                {
                    "prompt": str,
                    "response": str
                },
                ...
            ]

        - "user_info" (dict): the dictionary with all the fields in the users collection.

    Returns
    -------
    - {"status": False, "error": "..."} --> if an error occurred.
    - {"status": True, "result": {...}} --> if the call was successful. The expected structure of 
    the 'result' field is the following (with date string in ISO format, use the backend.utils.timing 
    library to parse/format):

        {
            "prompt": str, # the used prompt to get this tasks
            "response": str, # the response got from the LLM
            "tasks": {
                "date1":  {"title": str, "description": str, "difficulty": str},
                "date2":  {"title": str, "description": str, "difficulty": str},
                ...
            }
        }

    """
    url = LLM_SERVER_URL.rstrip("/") + "/generate-challenge"

    # 1. Robust Data Extraction
    goal = str(payload.get("goal")).strip() if payload.get("goal") else ""
    level = str(payload.get("level", "beginner")).lower()
    history_list = payload.get("history") if isinstance(payload.get("history"), list) else []
    if len(history_list) > 3:
        history_list = history_list[-3:]
    if len(history_list) > 3:
        history_list = history_list[-3:]
    # trim oversized responses inside history to reduce token usage
    safe_history: list = []
    for item in history_list:
        if not isinstance(item, dict):
            continue
        prompt_val = item.get("prompt")
        resp_val = item.get("response")
        if isinstance(resp_val, str) and len(resp_val) > 1000:
            resp_val = resp_val[:1000]
        safe_history.append({"prompt": prompt_val, "response": resp_val})
    history_list = safe_history

    # 2. Prepare Body
    # 2. Prepare Body with explicit caps to avoid LLM token overflow
    body = {
        "goal": goal,
        "level": level,
        "history": history_list,
    }
    # Cap total payload size heuristically (history already trimmed)
    if isinstance(body["goal"], str) and len(body["goal"]) > 500:
        body["goal"] = body["goal"][:500]
    if not body["goal"]:
        logger.error("Validation Error: Goal is empty after sanitation (input=%s)", goal)
        return {"status": False, "error": "Empty goal/prompt provided"}
    
    # 3. Prepare Headers --> include also the authentication token if available.
    headers = {"Content-Type": "application/json"}
    if LLM_SERVICE_TOKEN:
        headers["Authorization"] = f"Bearer {LLM_SERVICE_TOKEN}"

    # 4. Get the result by the LLM server
    response = communicate(url, body, headers)
    if not response["status"]:
        return {"status": False, "error": f"LLM server: {response.get('error')}"}

    # 5. Convert LLM challenge format (challenges_list) into tasks timeline expected downstream
    result = response.get("result") or {}
    challenge_data_raw = result.get("challenge_data")
    if isinstance(challenge_data_raw, dict):
        challenge_data: dict | None = challenge_data_raw
    else:
        challenge_data = None

    challenge_meta_raw = result.get("challenge_meta")
    if isinstance(challenge_meta_raw, dict):
        challenge_meta: dict | None = challenge_meta_raw
    elif isinstance(challenge_meta_raw, list):
        challenge_meta = next((item for item in challenge_meta_raw if isinstance(item, dict)), None)
    else:
        challenge_meta = None

    if challenge_data is None or challenge_meta is None:
        missing = "challenge_data" if challenge_data is None else "challenge_meta"
        error_msg = f"LLM response missing '{missing}': {result}"
        logger.error(error_msg)
        return {"status": False, "error": error_msg}

    challenges = challenge_data.get("challenges_list") or []
    if not challenges or int(challenge_data.get("challenges_count", 0) or 0) <= 0:
        err = challenge_data.get("error_message") or "LLM returned no challenges"
        return {"status": False, "error": err}
    available_days_raw = challenge_meta.get("preferred_days")
    available_days: list = available_days_raw if isinstance(available_days_raw, list) else []
    sorted_available_days = []
    tasks: dict[str, dict[str, Any]] = {}
    current_day = timing.now_local().date()
    for idx, ch in enumerate(challenges):
        if not sorted_available_days:
            sorted_available_days = timing.sort_days(
                days=available_days,
                enable_offset_wrt_today=True
            )
            if not sorted_available_days:
                sorted_available_days = timing.sort_days(
                    days=["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"],
                    enable_offset_wrt_today=True,
                )
        to_match_day = sorted_available_days.pop(0)
        while timing.weekday(current_day) != to_match_day:
            next_day = timing.next_day(current_day)
            current_day = next_day
        date_str = str(current_day)
        title = ch.get("challenge_title") or f"Challenge {idx+1}"
        desc = ch.get("challenge_description") or ""
        diff = str(ch.get("difficulty") or "easy")
        tasks[date_str] = {
            "title": title,
            "description": desc,
            "difficulty": diff
        }
        # advance by one day so repeated preferred days move forward (avoid overwriting same date)
        current_day = timing.next_day(current_day)

    raw_response = {
        "challenge_data": challenge_data_raw,
        "challenge_meta": challenge_meta_raw,
    }
    try:
        response_text = json.dumps(raw_response)
    except Exception as exc:  # pragma: no cover - best effort serialization
        logger.warning("Failed to serialize LLM raw response: %s", exc)
        response_text = json.dumps({"challenge_data": bool(challenge_data), "challenge_meta": bool(challenge_meta)})
    
    return {
        "status": True,
        "result": {
            "prompt": goal,
            "response": response_text,
            "tasks": tasks,
            "time_frame_days": challenge_meta.get("time_frame_days"),
            "preferred_days": challenge_meta.get("preferred_days"),
            "goal_title": challenge_meta.get("goal_title"),
            "raw_response": raw_response,
        }
    }
