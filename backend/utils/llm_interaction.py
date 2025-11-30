import json
import os
import logging
from pathlib import Path
from typing import Literal, Tuple, Dict, Any
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


def communicate(url: str, body: dict, headers: dict):
    '''
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
    '''

    # 1. Create session
    session = get_session(LLM_MAX_RETRIES, backoff_factor=0.3)

    # 2. Send request
    try:
        logger.info("Calling LLM server %s (goal len=%d)", url, len(body["goal"]))
        resp = session.post(url, json=body, timeout=LLM_TIMEOUT, headers=headers)
    except requests.RequestException as e:
        logger.error("Error contacting LLM server: %s", e, exc_info=True)
        return {"status": False, "error": f"LLM server unreachable: {str(e)}"}
    
    # 3. Handle response
    if resp.status_code != 200:
        content_snippet = (resp.text[:500] + "...") if resp.text else ""
        logger.warning("LLM server returned status %d: %s", resp.status_code, content_snippet)
        return {"status": False, "error": f"LLM server error ({resp.status_code})"}
    try:
        result = resp.json()
    except ValueError:
        logger.error("LLM server returned non-json response: %s", resp.text[:500])
        return {"status": False, "error": "Invalid JSON from LLM server"}
    
    return {"status": True, "result": result}


def get_llm_retask_response(payload: Dict[str, Any], target: Literal["plan","task"] = "plan") -> Dict[str, Any]:
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

    # 1. Data extraction
    goal = str(payload.get("goal")).strip() if payload.get("goal") else ""
    level = str(payload.get("level", "beginner")).lower()
    history_list = payload.get("history") if isinstance(payload.get("history"), list) else []

    # 2. Prepare Body --> ensure we don't convert None to "None" string.
    body = {
        "goal": goal,
        "level": level,
        "history": history_list,
        "last_prompt": history_list[-1]["prompt"] if history_list else "",
        "modification_reason": payload.get("modification_reason")
    }

    # 3. Prepare Headers --> include also the authentication token if available.
    headers = {"Content-Type": "application/json"}
    if LLM_SERVICE_TOKEN:
        headers["Authorization"] = f"Bearer {LLM_SERVICE_TOKEN}"

    # 4. Communication with the LLM server
    response = communicate(url, body, headers)
    result = response["result"]
    if not response["status"] and "error" in response:
        return {"status": False, "error": f"LLM server: {response.get('error')}"}
    if isinstance(result, dict) and ("error" in result or "detail" in result):
        msg = result.get("error") or result.get("detail") or "LLM server reported an error"
        return {"status": False, "error": f"LLM server: {msg}"}
    
    # 5. Convert LLM challenge format (challenges_list) into tasks timeline expected downstream
    challenges_data: dict | None = result.get("challenges_data") if isinstance(result, dict) else None
    if challenges_data is not None:
        ########### MODIFY THE "RETASKED" TASK ###########
        pass

    return {"status": True, "result": result}


def get_llm_response(payload: Dict[str, Any], target: Literal["plan","task"] = "plan") -> Dict[str, Any]:
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
    goal_text = payload.get("goal")
    goal = str(goal_text).strip() if goal_text else ""
    level = str(payload.get("level", "beginner")).lower()
    history_list = payload.get("history") if isinstance(payload.get("history"), list) else []

    # 2. Prepare Body
    body = {
        "goal": goal,
        "level": level,
        "history": history_list,
    }
    if not body["goal"]:
        logger.error("Validation Error: Goal is empty after sanitation (input=%s)", goal_text)
        return {"status": False, "error": "Empty goal/prompt provided"}
    
    # 3. Prepare Headers --> include also the authentication token if available.
    headers = {"Content-Type": "application/json"}
    if LLM_SERVICE_TOKEN:
        headers["Authorization"] = f"Bearer {LLM_SERVICE_TOKEN}"

    # 4. Get the result by the LLM server
    result = communicate(url, body, headers)
    if isinstance(result, dict) and ("error" in result or "detail" in result):
        msg = result.get("error") or result.get("detail") or "LLM server reported an error"
        return {"status": False, "error": f"LLM server: {msg}"}

    # 5. Convert LLM challenge format (challenges_list) into tasks timeline expected downstream
    challenges_data: dict | None = result.get("challenges_data") if isinstance(result, dict) else None
    if challenges_data is not None:
        challenges = challenges_data.get("challenges_list") or []
        tasks: dict[str, dict[str, Any]] = {}
        today = timing.now().date()
        for idx, ch in enumerate(challenges):
            date_str = str(today) ############# MODIFY WITH THE SCHEDULED VERSION OF THE DATES
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
            "error_message": result.get("error_message"),
        }
        return {"status": True, "result": converted}

    # 6. Legacy validation path
    is_valid, validation_error = validate_challenges(result)
    if not is_valid:
        logger.error("LLM response failed validation: %s -- response: %s", validation_error, str(result)[:500])
        return {"status": False, "error": f"Invalid LLM response: {validation_error}"}
    
    return {"status": True, "result": result}
