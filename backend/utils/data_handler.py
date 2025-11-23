import backend.db.database as db
from fastapi import HTTPException


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
            "gathered_info": [
                {
                    "question": str,
                    "answer": str
                },
                ...
            ]
        }
    '''
    questions_dict: dict = {
        0: "I tend to be hard on myself when I don't meet my own high expectations",
        1: "I prefer a predictable, steady routine over spontaneity and variety.",
        2: "I need to understand the logical reason behind a rule before I will follow it.",
        3: "I am more likely to finish a task if I know someone else is watching or counting on me.",
        4: "I often feel overwhelmed when I have too many choices to make.",
        5: "I find it difficult to stick with a task if I don't see immediate results.",
        6: "When I get stressed or busy, my personal habits are the first thing I drop.",
        7: "I am motivated by competition and proving I am better than others.",
        8: "I often make plans but struggle to actually start them.",
        9: "I believe that if I work hard enough, I can change almost anything about myself."
    }
    results = db.find_one(
        table_name="users", 
        filters={"user_id": user_id}, 
        projection={"_id": False, "height": True, "weight" : True, "sex" : True, "gathered_info" : True}
    )
    if results is None:
        raise HTTPException(status_code = 402, detail = "Invalid user projection")
    user_info = {
        "height": results["height"], 
        "weight": results["weight"], 
        "sex": results["sex"],
        "gathered_info": []
    }
    for i, value in enumerate(list(results["gathered_info"])):
        user_info["gatered_info"].append({"question": questions_dict[i], "answer": value})
    return user_info