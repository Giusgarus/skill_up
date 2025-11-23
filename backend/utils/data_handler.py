import json
import os
from pathlib import Path
import backend.db.database as db
from fastapi import HTTPException

_CONFIG_PATH = Path(__file__).resolve().parents[0] / "env.json"
if _CONFIG_PATH.exists():
    with _CONFIG_PATH.open("r", encoding="utf-8") as f:
        _cfg = json.load(f)
else:
    _cfg = {}

REGISTER_QUESTIONS: list = _cfg.get(
    "REGISTER_QUESTIONS",
    [s.replace("\"","") for s in str(os.getenv("REGISTER_QUESTIONS", "")).split(",") if s],
)
REGISTER_INTERESTS_LABELS: list = _cfg.get("REGISTER_INTERESTS_LABELS", [])


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
        ],
        "questions_info": [
            {"question": REGISTER_QUESTIONS[i], "answer": value}
            for i, value in enumerate(list(user.get("questions_info", [])))
        ]
    }
    return user_info
