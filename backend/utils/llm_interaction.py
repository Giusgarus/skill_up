import os
import logging
from typing import Tuple, Dict, Any
import requests
from requests.adapters import HTTPAdapter, Retry
from backend.utils import timing

# ---------------------------
# Client that calls LLM server
# ---------------------------
LLM_SERVER_URL = os.getenv("LLM_SERVER_URL", "http://localhost:8001")
LLM_SERVICE_TOKEN = os.getenv("LLM_SERVICE_TOKEN", None)
LLM_TIMEOUT = float(os.getenv("LLM_TIMEOUT", "10"))  # seconds
LLM_MAX_RETRIES = int(os.getenv("LLM_MAX_RETRIES", "2"))


def get_session(retries: int = 2, backoff_factor: float = 0.3) -> requests.Session:
    s = requests.Session()
    retry = Retry(
        total=retries,
        read=retries,
        connect=retries,
        backoff_factor=backoff_factor,
        status_forcelist=(429, 502, 503, 504),
        allowed_methods=frozenset(["POST", "GET", "PUT", "DELETE", "OPTIONS"])
    )
    s.mount("https://", HTTPAdapter(max_retries=retry))
    s.mount("http://", HTTPAdapter(max_retries=retry))
    return s


def validate_challenges(resp: Dict[str, Any]) -> Tuple[bool, str]:
    """
    Parameters
    ----------
    - resp (dict): the expected structure is the following (with date string in ISO format, 
    use the backend.utils.timing library to parse/format):

        {\n\t
            "prompt": str, # the used prompt to get this tasks\n\t
            "tasks": {\n\t\t
                "date1":  {"title": str, "description": str, "difficulty": str},\n\t\t
                "date2":  {"title": str, "description": str, "difficulty": str},\n\t\t
                ...\n\t
            }\n
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

        {\n\t
            "prompt": str, # the used prompt to get this tasks\n\t
            "response": str,\n\t
            "tasks": {\n\t\t
                "date1":  {"title": str, "description": str, "difficulty": str},\n\t\t
                "date2":  {"title": str, "description": str, "difficulty": str},\n\t\t
                ...\n\t
            }\n
        }

    """
    url = LLM_SERVER_URL.rstrip("/") + "/generate-challenge"
    
    # --- DEBUG PRINT START ---
    #print(f"DEBUG: send_json_to_llm_server received keys: {list(payload.keys())}")
    #print(f"DEBUG: payload['goal'] raw value: '{payload.get('goal')}'")
    # --- DEBUG PRINT END ---

    # 1. Robust Goal Extraction --> we check if 'goal' exists and is not None/Empty. If it is, we try 'prompt'.
    goal_text = payload.get("goal")
    if not goal_text: 
        goal_text = payload.get("prompt")

    # 2. History Extraction
    history_data = payload.get("history")

    # 3. Prepare Body --> ensure we don't convert None to "None" string.
    body = {
        "goal": str(goal_text).strip() if goal_text else "",
        "level": payload.get("level", "Beginner"),
        "user_info" : payload["user_info"],
        "history": history_data
    }
    if not body["goal"]:
        #logger.error(f"Validation Error: Goal came in as '{goal_text}', became '{body['goal']}'")
        return {"ok": False, "error": "Empty goal/prompt provided"}
    
    # 4. Prepare Headers --> include also the authentication token if available.
    headers = {"Content-Type": "application/json"}
    if LLM_SERVICE_TOKEN:
        headers["Authorization"] = f"Bearer {LLM_SERVICE_TOKEN}"

    # 5. Send Request
    session = get_session(retries=LLM_MAX_RETRIES)
    try:
        #logger.info("Calling LLM server %s (goal len=%d)", url, len(body["goal"]))
        resp = session.post(url, json=body, timeout=LLM_TIMEOUT, headers=headers)
    except requests.RequestException as e:
        #logger.error("Error contacting LLM server: %s", e, exc_info=True)
        return {"ok": False, "error": f"LLM server unreachable: {str(e)}"}
    
    # 6. Handle response
    if resp.status_code != 200:
        content_snippet = (resp.text[:500] + "...") if resp.text else ""
        #logger.warning("LLM server returned status %d: %s", resp.status_code, content_snippet)
        return {"ok": False, "error": f"LLM server error ({resp.status_code})"}
    try:
        result = resp.json()
    except ValueError:
        #logger.error("LLM server returned non-json response: %s", resp.text[:500])
        return {"ok": False, "error": "Invalid JSON from LLM server"}
    
    # 7. Check for errors in the result
    if isinstance(result, dict) and ("error" in result or "detail" in result):
        msg = result.get("error") or result.get("detail") or "LLM server reported an error"
        return {"ok": False, "error": f"LLM server: {msg}"}
    is_valid, validation_error = validate_challenges(result)
    if not is_valid:
        #logger.error("LLM response failed validation: %s -- response: %s", validation_error, str(result)[:500])
        return {"ok": False, "error": f"Invalid LLM response: {validation_error}"}
    
    return {"ok": True, "result": result}
