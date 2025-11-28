import os
import json
import logging
import re
import requests

from collections import defaultdict
from datetime import datetime, timedelta
from threading import Lock
from typing import List, Optional, Dict, Any

import google.generativeai as genai
from google.generativeai.types import HarmCategory, HarmBlockThreshold
from dotenv import load_dotenv
from fastapi import FastAPI, Query, Request, HTTPException, status, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel, Field, validator

SAFETY_SETTINGS = {
    HarmCategory.HARM_CATEGORY_HARASSMENT: HarmBlockThreshold.BLOCK_MEDIUM_AND_ABOVE,
    HarmCategory.HARM_CATEGORY_HATE_SPEECH: HarmBlockThreshold.BLOCK_MEDIUM_AND_ABOVE,
    HarmCategory.HARM_CATEGORY_SEXUALLY_EXPLICIT: HarmBlockThreshold.BLOCK_MEDIUM_AND_ABOVE,
    HarmCategory.HARM_CATEGORY_DANGEROUS_CONTENT: HarmBlockThreshold.BLOCK_MEDIUM_AND_ABOVE,
}


model = genai.GenerativeModel(
    "gemini-2.5-flash",
    safety_settings=SAFETY_SETTINGS
)
# -----------------------
# Core AI Function
# -----------------------
logger = logging.getLogger(__name__)

def generate_challenge(goal: str, level: str, history: List[Dict[str, Any]]):
    sanitized_goal, sanitized_level, sanitized_history, error = validate_and_sanitize_input(goal, level, history)
    if error:
        raise ValueError(error)

    system_instruction = """You are 'SkillUp Coach,' an expert AI gamification engine designed to turn personal habits and corporate skills into an RPG-style adventure.

    YOUR MISSION:
    Create engaging, bite-sized mini-challenges based on the user's goal. Your tone must be motivating, clear, and energetic (like a game quest giver).

    CRITICAL GUIDELINES:
    1. JSON ONLY: Output must be raw JSON. Do NOT use markdown code blocks (```json).
    2. SAFETY: No dangerous, illegal, or physically harmful quests.
    3. VIABILITY: If the goal is impossible within the constraints, set "challenges_count" to 0 and "error_message" to "Quest invalid."
    4. SCHEDULING: Challenges do not need to be daily. Space them out based on the user's availability.
    5. DURATION: Challenges must take 5-30 minutes.

    Prefer active verbs and concise instructions. Avoid filler words:
    EXAMPLES OF PASSIVE vs. ACTIVE TRANSLATION:
    - User Goal: "Learn Spanish"
      BAD (Passive): "Read a list of kitchen vocabulary."
      GOOD (Active): "The Labeling Quest: Write Spanish labels on sticky notes and attach them to 5 items in your kitchen."

    - User Goal: "Get Fit"
      BAD (Passive): "Watch a video on proper squat form."
      GOOD (Active): "The Form Check: Record a 10-second video of yourself doing 5 squats, then watch it to self-correct your posture."

    - User Goal: "Learn Marketing"
      BAD (Passive): "Study how to write a hook."
      GOOD (Active): "The Viral Hook: Write 3 different opening tweets for a hypothetical product launch."
    
    OUTPUT SCHEMA:
    {
        "challenges_count": <int>,
        "challenges_list": [
            {
                "challenge_title": "Quest Name (Max 20 chars)",
                "challenge_description": "Specific action instructions. 1-2 sentences.",
                "duration_minutes": <int>,
                "difficulty": "<Easy|Medium|Hard>",
                "day_offset": <int> // 0 for today, 1 for tomorrow, etc.
            }
        ],
        "error_message": null // or string if invalid
    }
    """
    
    user_prompt = f"""
    **PLAYER PROFILE:**
    - **Goal:** "{sanitized_goal}"
    - **Current Level:** {sanitized_level}
    - **History:** {json.dumps(sanitized_history) if sanitized_history else "New Player"}

    **MISSION REQUEST:**
    Generate a quest line starting from today.
    1. **Relevance:** Directly help achieve the goal.
    2. **Progression:** If history exists, increase difficulty slightly.
    3. **Format:** Punchy titles, clear bullet points.
    """

    try:
        logger.info("Generating challenge for sanitized goal: %s...", sanitized_goal[:50])

        response = model.generate_content(
            [system_instruction, user_prompt],
            generation_config={
                "temperature": 0.7,
                "top_p": 0.95,
                "max_output_tokens": 2524,
                "response_mime_type": "application/json",
            }
        )

        # Safety filter check / empty response
        if not response or not hasattr(response, "text") or not response.text:
            if hasattr(response, "prompt_feedback"):
                logger.warning("Response blocked by safety filters: %s", response.prompt_feedback)
                raise ValueError("Request blocked by safety filters. Please rephrase your goal.")
            raise ValueError("Empty response from AI model")

        logger.info("Raw API response: %s...", (response.text[:400] if response.text else "None"))
        json_text = response.text.strip()

        # strip triple-backtick codeblocks if present
        if json_text.startswith("```"):
            parts = json_text.split("```")
            if len(parts) >= 2:
                json_text = parts[1]
                if json_text.startswith("json"):
                    json_text = json_text[4:]
                json_text = json_text.strip()

        challenge_data = json.loads(json_text)

        is_valid, validation_error = validate_ai_response(challenge_data)
        if not is_valid:
            logger.error("AI response validation failed: %s", validation_error)
            raise ValueError(f"Invalid AI response: {validation_error}")

        logger.info("Challenge generated and validated successfully")
        return challenge_data

    except json.JSONDecodeError as e:
        logger.error("JSON parsing error: %s", e)
        logger.error("Response text: %s", response.text if response else "None")
        raise ValueError("Failed to parse AI response")
    except Exception as e:
        logger.error("Error generating challenge: %s", str(e), exc_info=True)
        raise



# -----------------------
# Validation & Sanitization
# -----------------------
def validate_and_sanitize_input(goal: str, level: str=None, history: List[Dict[str, Any]]=None):
    # 1. length + trivial checks handled by pydantic, but keep extra checks
    
    #################### WE SHOULD CHECK IF THIS LENGTH (500) IS RESTRICTIVE ENOUGH ##############
    if len(goal) > 500:
        return None, None, None, "Goal exceeds maximum length of 500 characters"

    goal_lower = goal.lower()

    # 2. prompt injection patterns
    injection_patterns = [
        r"ignore\s+(previous|above|all)\s+instructions?",
        r"disregard\s+(previous|above|all)",
        r"forget\s+(everything|previous|above)",
        r"new\s+instructions?:",
        r"system\s*:",
        r"assistant\s*:",
        r"override\s+",
        r"act\s+as\s+",
        r"pretend\s+(you are|to be)",
        r"you\s+are\s+now",
        r"jailbreak",
        r"<\s*script",
        r"</?\s*prompt\s*>",
        r"{{.*}}",
    ]

    for pattern in injection_patterns:
        if re.search(pattern, goal_lower, re.IGNORECASE):
            logger.warning("Potential prompt injection detected: %s", pattern)
            return None, None, None, "Invalid input detected. Please rephrase your goal."

    # 3. malicious keywords
    malicious_keywords = [
        "hack", "exploit", "illegal", "drugs", "weapons",
        "violence", "harm", "suicide", "self-harm", "prompt"
    ]
    suspicious_word_count = sum(1 for w in malicious_keywords if w in goal_lower)
    if suspicious_word_count >= 2:
        logger.warning("Suspicious content detected in goal")
        return None, None, None, "Goal contains inappropriate content"

    # 4. remove dangerous characters
    sanitized_goal = re.sub(r'[^\w\s.,!?\-\'"()]', "", goal).strip()
    if sanitized_goal and not level and not history:
        return sanitized_goal, None, None, None
    
    # 5. level
    valid_levels = ["beginner", "intermediate", "advanced"]
    sanitized_level = level.lower()
    if sanitized_level not in valid_levels:
        sanitized_level = "beginner"

    # 6. history sanitization
    if not isinstance(history, list):
        history = []
    # If we have history we keep the last 20 requests by the user. I think we won't have that many!!!
    if len(history) > 3:
        history = history[-1:]

    sanitized_history = []
    for item in history:
        if isinstance(item, dict):
            safe_item = {
                "title": str(item.get("title", ""))[:100],
                "completed": bool(item.get("completed", False))
            }
            sanitized_history.append(safe_item)
    
    # client = language.LanguageServiceClient()
    # document = language.Document(
    #     content=goal,
    #     type_=language.Document.Type.PLAIN_TEXT,
    # )
    # goal_toxicity_review = client.moderate_text(document=document)
    # print(goal_toxicity_review)
    
    return sanitized_goal, sanitized_level, sanitized_history, None

def validate_ai_response(response_data: dict):
    # CORRECTED KEYS (Fixed spelling: 'challenges')
    required_keys = ["challenges_list", "challenges_count"]
    required_secondary_keys = ["challenge_title", "challenge_description", "difficulty"]
    
    length = 0
    full_answer_txt = ""

    # 1. Validate Top Level Structure
    if not all(k in response_data for k in required_keys):
        return False, "Invalid response structure: Missing top-level keys"
    
    if not isinstance(response_data["challenges_list"], list):
        return False, "Invalid format: challenges_list must be a list"
    
    if not isinstance(response_data["challenges_count"], int):
        return False, "Invalid format: challenges_count must be an integer"

    # 2. Validate Each Challenge inside the list
    for challenge in response_data["challenges_list"]:
        # Check secondary keys existence
        if not all(k in challenge for k in required_secondary_keys):
            return False, "Invalid response structure: Missing secondary keys"

        # Validate Data Types
        if not isinstance(challenge["challenge_title"], str):
            return False, "Invalid title format"
        if not isinstance(challenge["challenge_description"], str):
            return False, "Invalid description format"
        if not isinstance(challenge["difficulty"], str):
            return False, "Invalid difficulty format"

        # Validate Values / Constraints
    
        # Difficulty fallback
        if challenge["difficulty"] not in ["Easy", "Medium", "Hard"]:
            challenge["difficulty"] = "Easy"

        # Length Truncation (CRITICAL FIX: referencing 'challenge', not 'response_data')
        if len(challenge["challenge_title"]) > 100:
            challenge["challenge_title"] = challenge["challenge_title"][:100]
        if len(challenge["challenge_description"]) > 200:
            challenge["challenge_description"] = challenge["challenge_description"][:500]

        # Accumulate text for safety check
        length += len(challenge["challenge_title"]) + len(challenge["challenge_description"])
        full_answer_txt += " " + (challenge["challenge_title"] + " " + challenge["challenge_description"]).lower()

    if length > 2000: # Increased slightly to allow for multiple challenges
        return False, "Response too lengthy"

    # 3. Safety / XSS Check
    dangerous_patterns = [r"<script", r"javascript:", r"onerror=", r"onclick=", r"eval\(", r"<iframe", r"prompt"]
    for pattern in dangerous_patterns:
        if re.search(pattern, full_answer_txt, re.IGNORECASE):
            return False, "Response contains potentially harmful content"

    return True, None


def replan_task(goal:str, level:str, previous_task:str, llm_response:str, modificaiton_reason: Optional[str] = ""):
    try:
        existing_data = json.loads(llm_response)
    except json.JSONDecodeError:
        raise ValueError("Failed to parse existing LLM response")
    sanitized_goal, _,_,error= validate_and_sanitize_input(goal)
    system_instruction = """You are 'SkillUp Coach,' an expert AI gamification engine designed to turn personal habits and corporate skills into an RPG-style adventure.

    YOUR MISSION:
    Replace the previously generated task with a new one that fits the whole generated plan based on the user's goal and modification reason. Your tone must be motivating, clear, and energetic (like a game quest giver).
    CRITICAL GUIDELINES:
    1. JSON ONLY: Output must be raw JSON. Do NOT use markdown code blocks (```json).
    2. SAFETY: No dangerous, illegal, or physically harmful quests.
    3. VIABILITY: If the modificaiton_reason is impossible within the constraints, set "error_message" to "Quest invalid."
    4. SCHEDULING: Exactly match the day_offset of the previous_task. 
    5. DURATION: Challenges must take 5-30 minutes.

    Prefer active verbs and concise instructions. Avoid filler words:
    EXAMPLES OF PASSIVE vs. ACTIVE TRANSLATION:
    - User Goal: "Learn Spanish"
      BAD (Passive): "Read a list of kitchen vocabulary."
      GOOD (Active): "The Labeling Quest: Write Spanish labels on sticky notes and attach them to 5 items in your kitchen."

    - User Goal: "Get Fit"
      BAD (Passive): "Watch a video on proper squat form."
      GOOD (Active): "The Form Check: Record a 10-second video of yourself doing 5 squats, then watch it to self-correct your posture."

    - User Goal: "Learn Marketing"
      BAD (Passive): "Study how to write a hook."
      GOOD (Active): "The Viral Hook: Write 3 different opening tweets for a hypothetical product launch."
    
    OUTPUT SCHEMA:
    {
        "challenge_title": "Quest Name (Max 20 chars)",
        "challenge_description": "Specific action instructions. 1-2 sentences.",
        "duration_minutes": <int>,
        "difficulty": "<Easy|Medium|Hard>",
        "day_offset": The same offset provided in the task the user wants to change.
    }
    
    examples:
    example 1:
    goal: "I want to learn Spanish"
    level: "beginner"
    previous_task: { "challenge_title": "The Labeling Quest", "challenge_description": "Write Spanish labels on sticky notes and attach them to 5 items in your kitchen.", "duration_minutes":15, "difficulty": "Easy",  "day_offset":5}
    llm_response: The original LLM response in JSON format containing the list of the tasks
    modification_reason: "I don't have sticky notes available"
    
    new_task: { "challenge_title": "The Vocabulary List", "challenge_description": "Create a list of 10 common kitchen items in Spanish and practice pronouncing them aloud.", "duration_minutes":15, "difficulty": "Easy", "day_offset":5}
    
    example 2
    goal: "I want to learn Python programming"
    level: "beginner"
    previous_task: { "challenge_title": "Loopy land", "challenge_description": "Create a loop in Python using a while loop and a for loop and compare between them", "duration_minutes":25, "difficulty": "Easy", "day_offset":2}
    llm_response: The original LLM response in JSON format containing the list of the tasks
    modification_reason: "I am outside and can't code right now"
    
    new_task: { "challenge_title": "Video Tutorial", "challenge_description": "Wathc a youtube video explaining while and for loops in python and think of an example usage for each one", "duration_minutes":20, "difficulty": "Easy", "day_offset":2}
    
    """
    
    
    user_prompt = f"""
        **PLAYER PROFILE:**
        - **Goal:** "{sanitized_goal}"
        - **Current Level:** "{level}"
        - **previous_task:** "{previous_task}"
        - **llm_response:** "{llm_response}"
        - **modification_reason:** "{modificaiton_reason}"
        **MISSION REQUEST:**
        Generate a new task substituting the previous_task based on the context of the modification_reason, llm_response, and previous_task.
        1. **Relevance:** Directly help achieve the goal.
        2. **Progression:** If history exists, increase difficulty slightly.
        3. **Format:** Punchy titles, clear bullet points.
        """

    try:
        logger.info("Generating challenge for sanitized goal: %s...", sanitized_goal[:50])

        response = model.generate_content(
            [system_instruction, user_prompt],
            generation_config={
                "temperature": 0.7,
                "top_p": 0.95,
                "max_output_tokens": 500,
                "response_mime_type": "application/json",
            }
        )

        # Safety filter check / empty response
        if not response or not hasattr(response, "text") or not response.text:
            if hasattr(response, "prompt_feedback"):
                logger.warning("Response blocked by safety filters: %s", response.prompt_feedback)
                raise ValueError("Request blocked by safety filters. Please rephrase your goal.")
            raise ValueError("Empty response from AI model")

        logger.info("Raw API response: %s...", (response.text[:400] if response.text else "None"))
        json_text = response.text.strip()

        # strip triple-backtick codeblocks if present
        if json_text.startswith("```"):
            parts = json_text.split("```")
            if len(parts) >= 2:
                json_text = parts[1]
                if json_text.startswith("json"):
                    json_text = json_text[4:]
                json_text = json_text.strip()

        challenge_data = json.loads(json_text)

        is_valid, validation_error = validate_ai_response(challenge_data)
        if not is_valid:
            logger.error("AI response validation failed: %s", validation_error)
            raise ValueError(f"Invalid AI response: {validation_error}")

        logger.info("Challenge generated and validated successfully")
        return challenge_data
    
    
    except json.JSONDecodeError as e:
        logger.error("JSON parsing error: %s", e)
        logger.error("Response text: %s", response.text if response else "None")
        raise ValueError("Failed to parse AI response")
    except Exception as e:
        logger.error("Error generating challenge: %s", str(e), exc_info=True)
        raise