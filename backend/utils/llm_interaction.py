import json
import os
import logging
from pathlib import Path
from typing import Tuple, Dict, Any
from datetime import timedelta
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


def get_llm_response(payload: Dict[str, Any]) -> Dict[str, Any]:
    """
    Parameters
    ----------
    - payload (dict): the expected keys are:
        - "goal" (str): the goal written by the user,
        - "level" (int): the level of the user for that plan,
        - "history" (list): history of the previous prompts/responses for that user,
        - "user_info" (dict): the dictionary with all the fields in the users collection.

    Returns
    -------
    - {"ok": False, "error": "..."} --> if an error occurred.
    - {"ok": True, "result": {...}} --> if the call was successful. The expected structure of 
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

    # 1. Robust Goal Extraction --> we check if 'goal' exists and is not None/Empty. If it is, we try 'prompt'.
    goal_text = payload.get("goal") or payload.get("prompt")
    goal = str(goal_text).strip() if goal_text else ""

    # 2. History Extraction -> the LLM service expects a list, so coerce/ignore invalid shapes.
    history_data = payload.get("history")
    history_list: list = []
    if isinstance(history_data, list):
        history_list = history_data
        
        
    # print("THE LAST RESPONSE:", history_list[-1])
    
    
    # 3. Prepare Body --> ensure we don't convert None to "None" string.
    body = {
        "goal": goal,
        "level": str(payload.get("level", "beginner")).lower(),
        "history": history_list,
    }
    if not body["goal"]:
        logger.error("Validation Error: Goal is empty after sanitation (input=%s)", goal_text)
        return {"ok": False, "error": "Empty goal/prompt provided"}
    
    # 4. Prepare Headers --> include also the authentication token if available.
    headers = {"Content-Type": "application/json"}
    if LLM_SERVICE_TOKEN:
        headers["Authorization"] = f"Bearer {LLM_SERVICE_TOKEN}"

    # 5. Create session
    session = get_session(LLM_MAX_RETRIES, backoff_factor=0.3)

    # 6. Send request
    try:
        logger.info("Calling LLM server %s (goal len=%d)", url, len(body["goal"]))
        resp = session.post(url, json=body, timeout=LLM_TIMEOUT, headers=headers)
    except requests.RequestException as e:
        logger.error("Error contacting LLM server: %s", e, exc_info=True)
        return {"ok": False, "error": f"LLM server unreachable: {str(e)}"}
    
    # 7. Handle response
    if resp.status_code != 200:
        content_snippet = (resp.text[:500] + "...") if resp.text else ""
        logger.warning("LLM server returned status %d: %s", resp.status_code, content_snippet)
        return {"ok": False, "error": f"LLM server error ({resp.status_code})"}
    try:
        result = resp.json()
    except ValueError:
        logger.error("LLM server returned non-json response: %s", resp.text[:500])
        return {"ok": False, "error": "Invalid JSON from LLM server"}
    
    # 8. Check for errors in the result
    if isinstance(result, dict) and ("error" in result or "detail" in result):
        msg = result.get("error") or result.get("detail") or "LLM server reported an error"
        return {"ok": False, "error": f"LLM server: {msg}"}

    # 9. Convert LLM challenge format (challenges_list) into tasks timeline expected downstream
    if isinstance(result, dict) and "challenges_list" in result:
        challenges = result.get("challenges_list") or []
        tasks: dict[str, dict[str, Any]] = {}
        today = timing.now().date()
        for idx, ch in enumerate(challenges):
            date_str = (today + timedelta(days=ch.get("day_offset"))).isoformat()
            title = ch.get("challenge_title") or f"Challenge {idx+1}"
            desc = ch.get("challenge_description") or ""
            diff = str(ch.get("difficulty") or "easy")
            tasks[date_str] = {
                "title": title,
                "description": desc,
                "difficulty": diff,
            }
        converted = {
            "prompt": body["goal"],
            "response": result,
            "tasks": tasks,
            "n_tasks": len(tasks),
        }
        return {"status": True, "result": converted}

    # 10. Legacy validation path
    is_valid, validation_error = validate_challenges(result)
    if not is_valid:
        logger.error("LLM response failed validation: %s -- response: %s", validation_error, str(result)[:500])
        return {"ok": False, "error": f"Invalid LLM response: {validation_error}"}
    
    return {"status": True, "result": result}
