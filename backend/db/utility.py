
table_primary_keys_dict = {
    "users": ["user_id", "username"],
    "tasks": ["task_id", "user_id"],
    "sessions": ["token"],
    "leaderboard": ["username"],
}

def check_primary_keys(table_name: str, record: dict):
    primary_keys = table_primary_keys_dict[table_name]
    for k in primary_keys:
        if k not in record.keys():
            return False
    return True
