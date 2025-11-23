import os
import backend.db.database as db
from fastapi import HTTPException


REGISTER_QUESTIONS: list = [s.replace("\"","") for s in str(os.getenv("REGISTER_QUESTIONS", None)).split(",")]
REGISTER_INTERESTS_LABELS: list = list(os.getenv("REGISTER_INTERESTS_LABELS", []))


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
        projection={"_id": False, "height": True, "weight" : True, "sex" : True, "selections_info": True, "questions_info" : True}
    )
    if user is None:
        raise HTTPException(status_code = 402, detail = "Invalid user projection")
    user_info = {
        "height": user["height"], 
        "weight": user["weight"], 
        "sex": user["sex"],
        "interests_info": [
            REGISTER_INTERESTS_LABELS[idx]
            for idx in user["interests_info"]
        ],
        "questions_info": [
            {"question": REGISTER_QUESTIONS[i], "answer": value}
            for i, value in enumerate(list(user["questions_info"]))
        ]
    }
    return user_info