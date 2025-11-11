
table_primary_keys_dict = {
    "users": [("user_id"), ("username"), ("email")],
    "tasks": [("task_id", "user_id")],
    "sessions": [("token")],
    "leaderboard": [("_id")],
}

def check_primary_keys(table_name: str, record: dict):
    primary_keys = table_primary_keys_dict[table_name]
    for k_list in primary_keys:
        if k_list in record.keys():
            return True
    return False
