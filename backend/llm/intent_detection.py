# USER_INTENTS = ["health","mindfulness", "productivity", "career", "learning", "financial", "creativity", "sociality", "home", "digital_detox"]
from dotenv import load_dotenv
import requests
import json
import logging
import os
import time
import re
import random
load_dotenv()
logger = logging.getLogger(__name__)
api_key = os.getenv("QWEN_API_KEY")
print("API KEY:", api_key)
if not api_key:
    logger.error("QWEN_API_KEY environment variable not set.")
    raise RuntimeError("Missing required environment variable: QWEN_API_KEY")
OPENROUTER_API_KEY = api_key
MODEL = "meituan/longcat-flash-chat:free"
ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"  # OpenAI-compatible endpoint

ALLOWED_INTENTS = ["health","mindfulness", "productivity", "career", "learning", "financial", "creativity", "sociality", "home", "digital_detox"]     

HEALTH_KEYWORDS = [
    "exercise","workout","run","gym","sleep","sleeping","diet","calorie","health","fit","fitness",
    "muscle","muscles","bulk","bulking","strength","strong","lift","weights","weight","physique","bodybuild","bodybuilding",
]

INTENT_KEYWORDS = {
    "health": HEALTH_KEYWORDS,
    "mindfulness": ["meditat","mindful","breathe","breath","anxiety","mindfulness","calm","ground"],
    "productivity": ["productiv","focus","pomodoro","task","todo","plan","workflow","work better"],
    "career": ["resume","cv","career","interview","job","promotion","networking","linkedin"],
    "learning": ["learn","study","course","practice","tutorial","lesson","homework","study plan"],
    "financial": ["money","budget","save","saving","invest","investment","debt","loan","finance"],
    "creativity": [
        "write","draw","paint","compose","idea","sketch","creativ","story","poem",
        "sing","song","music","musical","melody","lyrics","vocal","voice","choir","guitar","piano",
    ],
    "sociality": ["friend","social","party","date","meet","network","introduce","small talk"],
    "home": ["clean","declutter","organize","repair","apartment","home","house","garden", "cook", "chore"],
    "digital_detox": ["phone","social media","screen time","unplug","disconnect","digital detox"]
}
        
# Tunables
MAX_RETRIES = 4
BASE_BACKOFF = 1.0
TIMEOUT = 30
FALLBACK_TO_LOCAL = True  # use local rule-based detector when remote fails


def _strip_replan_noise(text: str) -> str:
    """Remove the marker words 'replan request' but keep the surrounding goal text."""
    if not isinstance(text, str):
        return ""
    cleaned = re.sub(r"\breplan\s+request\b", " ", text, flags=re.IGNORECASE)
    cleaned = re.sub(r"\s{2,}", " ", cleaned)
    return cleaned.strip()

# --- Local rule-based fallback (simple, quick) ---
def _best_intent_by_keywords(text: str) -> tuple[str, int]:
    """Return best intent guess and score using keyword heuristics."""
    t = _strip_replan_noise(text).lower()
    scores = {k: 0 for k in INTENT_KEYWORDS}
    for intent, kws in INTENT_KEYWORDS.items():
        for kw in kws:
            if kw in t:
                scores[intent] += 1
    best, best_score = max(scores.items(), key=lambda kv: kv[1])
    return (best if best_score > 0 else "other", best_score)


def _local_rule_based_detector(text: str) -> str:
    best, score = _best_intent_by_keywords(text)
    return best if score > 0 else "other"

# --- Utility: try to parse JSON from model "content" robustly ---
def _extract_json_from_text(s: str):
    if not s or not isinstance(s, str):
        return None
    # Try direct json.loads first
    try:
        parsed = json.loads(s)
        if isinstance(parsed, dict):
            return parsed
    except Exception:
        pass

    # Try to extract the first {...} balanced braces substring
    # This handles cases where the model returns extra text before/after the JSON.
    # We'll find the outermost first '{' and last '}' and attempt to load.
    start = s.find('{')
    end = s.rfind('}')
    if start != -1 and end != -1 and end > start:
        candidate = s[start:end+1]
        try:
            parsed = json.loads(candidate)
            if isinstance(parsed, dict):
                return parsed
        except Exception:
            # As a last resort, try to fix some common issues (e.g., single quotes)
            candidate2 = candidate.replace("'", "\"")
            try:
                parsed = json.loads(candidate2)
                if isinstance(parsed, dict):
                    return parsed
            except Exception:
                pass

    # Try to find key:value style like intent: "x" (without JSON). regex:
    m = re.search(r'["\']?intent["\']?\s*[:=]\s*["\']?([a-zA-Z0-9_ -]+)["\']?', s)
    if m:
        return {"intent": m.group(1).strip()}

    return None

# --- Core remote call + extraction ---
def _call_remote_intent_detector(goal: str):
    if not OPENROUTER_API_KEY:
        logger.info("No API key configured; skipping remote detection.")
        return None

    system_instruction = (
        "You are an expert intent detector that extracts the user's intent from their input. "
        "You have this list of possible intents: " + json.dumps(ALLOWED_INTENTS) + 
        ". Return ONLY a single JSON object with the key 'intent' whose value is one of the list. "
        "If none match, return {\"intent\": \"other\"} and nothing else."
    )
    messages = [
        {"role": "system", "content": system_instruction},
        {"role": "user", "content": goal}
    ]
    payload = {
        "model": MODEL,
        "messages": messages,
        "temperature": 0.0,
        "top_p": 0.95,
        "max_tokens": 500
    }
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {OPENROUTER_API_KEY}"
    }

    backoff = BASE_BACKOFF
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            logger.debug("Remote intent attempt %d for goal: %.120s", attempt, goal)
            resp = requests.post(ENDPOINT, headers=headers, json=payload, timeout=TIMEOUT)
            logger.info("Remote detect HTTP %s", resp.status_code)
            if resp.status_code == 200:
                data = resp.json()
                # defensive navigation of response structure
                choices = data.get("choices") or []
                if not choices:
                    logger.warning("No choices in remote response.")
                    return None
                # try typical OpenRouter/OpenAI location(s)
                message = choices[0].get("message") or {}
                content = message.get("content") or choices[0].get("text") or None
                if content is None:
                    logger.warning("No content found in choice[0].")
                    return None
                logger.debug("Raw model content: %s", content)
                parsed = _extract_json_from_text(content)
                if parsed and isinstance(parsed, dict):
                    intent_val = parsed.get("intent")
                    if isinstance(intent_val, str) and intent_val in ALLOWED_INTENTS:
                        return intent_val
                    # normalize small variants
                    if isinstance(intent_val, str):
                        iv = intent_val.strip().lower()
                        # try to match roughly
                        for allowed in ALLOWED_INTENTS:
                            if iv == allowed.lower():
                                return allowed
                # If parsed but invalid or missing 'intent', warn and return None
                logger.warning("Parsed remote JSON invalid or missing 'intent': %s", parsed)
                return None

            elif resp.status_code == 429:
                jitter = random.uniform(0, min(backoff, 3))
                sleep_for = min(backoff + jitter, 30.0)
                logger.warning("Rate limited (429). Backing off %.2fs (attempt %d/%d).", sleep_for, attempt, MAX_RETRIES)
                time.sleep(sleep_for)
                backoff *= 2
                continue
            elif 500 <= resp.status_code < 600:
                # server error -> retry
                jitter = random.uniform(0, 1.0)
                sleep_for = min(backoff + jitter, 30.0)
                logger.warning("Server error %d; retrying in %.2fs.", resp.status_code, sleep_for)
                time.sleep(sleep_for)
                backoff *= 2
                continue
            else:
                # client error or other -> do not retry
                logger.error("Remote detection failed HTTP %d: %s", resp.status_code, resp.text[:400])
                return None

        except requests.Timeout:
            logger.warning("Remote request timed out; attempt %d/%d", attempt, MAX_RETRIES)
            time.sleep(min(backoff, 30))
            backoff *= 2
            continue
        except requests.RequestException as e:
            logger.exception("RequestException during remote detect: %s", e)
            return None

    logger.error("Remote detection exhausted retries.")
    return None

# --- Public function ---
def detect_intent(goal: str) -> str:
    """
    Returns a single intent string from ALLOWED_INTENTS. Always returns a valid intent
    (defaults to "other" when uncertain). Uses remote model when possible, with
    parsing, retries and a local fallback.
    """
    if not isinstance(goal, str) or goal.strip() == "":
        return "other"
    goal_for_detection = _strip_replan_noise(goal)

    # 1) Try remote
    remote = _call_remote_intent_detector(goal_for_detection)
    if remote:
        local_guess, local_score = _best_intent_by_keywords(goal_for_detection)
        if remote != local_guess and local_score > 0:
            logger.info("Remote intent %s overridden to %s based on strong keyword signals", remote, local_guess)
            return local_guess
        logger.info("Remote detected intent: %s", remote)
        return remote

    # 2) Fallback to local rule-based detector
    if FALLBACK_TO_LOCAL:
        local = _local_rule_based_detector(goal_for_detection)
        logger.info("Local fallback detected intent: %s", local)
        return local

    # 3) default
    return "other"








# def detect_intent(goal: str) -> None:

#     # Build messages (system, user, assistant) similar to your genai usage
#     messages = [
#         {"role": "system", "content": """You are an expert intent detector that extracts the user's intent from their input. 
#         You have a determined list of possible intents you can choose from: ["health","mindfulness", "productivity", "career", "learning", "financial", "creativity", "sociality", "home", "digital_detox", "other"]
#         You only return one intent from the list that best matches the user's input. In none of the intents match, return "other".
#         output format: {"intent": <str>}
#         """},
#         {"role": "user", "content": goal},
#         {"role": "assistant", "content": """example1: {"goal": "I want to improve my productivity at work"} -> {"intent": "productivity"}
#         example2: {goal: "I want to be more social and make new friends"} -> {intent: "sociality"}"""}
#     ]

#     payload = {
#         "model": MODEL,
#         "messages": messages,
#         # Map your generation_config:
#         "temperature": 0.0,
#         "top_p": 0.95,
#         # OpenAI-compatible param name is usually "max_tokens"
#         "max_tokens": 1000,   # be careful: very large values may be rejected; reduce if you get errors
#         # If you need structured/json output you can request assistant to return JSON, or use model features:
#         # "response_format": "application/json"  # not standard — prefer instructing the model to output JSON
#     }

#     headers = {
#         "Content-Type": "application/json",
#         "Authorization": f"Bearer {OPENROUTER_API_KEY}"
#     }

#     resp = requests.post(ENDPOINT, headers=headers, json=payload, timeout=60)
#     logger.info(f"OpenRouter response status: {resp.status_code}")
    
#     if resp.status_code == 200:
#         data = resp.json()
#         # OpenRouter returns OpenAI-compatible response structure; message is usually at:
#         # data["choices"][0]["message"]["content"]
#         logger.info(f"OpenRouter response data: {data}")
#         print(json.dumps(data, indent=2))
#     elif resp.status_code == 429:
#         print("Rate limited (429). You have exceeded free-model RPM or daily quota.")
#     else:
#         print(f"HTTP {resp.status_code}: {resp.text}")
