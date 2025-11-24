import json
import os
from pathlib import Path
import backend.db.database as db
from fastapi import HTTPException

_CONFIG_PATH = Path(__file__).resolve().parents[0] / "env.json"
with _CONFIG_PATH.open("r", encoding="utf-8") as f:
    _cfg = json.load(f)

REGISTER_QUESTIONS: list = (
    _cfg.get("REGISTER_QUESTIONS")
    or _cfg.get("GATHERING_QUESTIONS")
    or []
)
REGISTER_INTERESTS_LABELS: list = (
    _cfg.get("REGISTER_INTERESTS_LABELS")
    or _cfg.get("GATHERING_INTERESTS_LABELS")
    or []
)


def get_user_info(user_id: str) -> dict:
    '''
    Retrieve user information.

    Parameters
    ----------
    - user_id (str): The ID of the user.

    Returns
    -------
    - dict: A dictionary containing user information in the following format:

        {
            "height": float,
            "weight": float,
            "sex": str,
            "interests_info": list[str], # list of words describing the interests
            "questions_info": [
                {
                    "question": str,
                    "answer": str
                },
                ...
            ]
        }
    '''
    user = db.find_one(
        table_name="users",
        filters={"user_id": user_id},
        projection={
            "_id": False,
            "height": True,
            "weight": True,
            "sex": True,
            "selections_info": True,
            "interests_info": True,
            "questions_info": True,
        },
    )
    if user is None:
        raise HTTPException(status_code = 402, detail = "Invalid user projection")
    user_info = {
        "height": user.get("height"),
        "weight": user.get("weight"),
        "sex": user.get("sex"),
        "interests_info": [
            REGISTER_INTERESTS_LABELS[idx]
            for idx in user.get("interests_info") or user.get("selections_info") or []
            if 0 <= idx < len(REGISTER_INTERESTS_LABELS)
        ]}
    questions_info = []
    for i, value in enumerate(list(user.get("questions_info", []))):
        question_text = REGISTER_QUESTIONS[i] if i < len(REGISTER_QUESTIONS) else None
        questions_info.append({"question": question_text, "answer": value})
    user_info["questions_info"] = questions_info
    return user_info
