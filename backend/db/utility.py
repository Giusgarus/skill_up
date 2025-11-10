
table_primary_keys_dict = {
    "users": ["user_id", "username", "email"],
    "tasks": ["task_id", "user_id"],
    "sessions": ["token"],
    "leaderboard": ["_id"],
}

def check_primary_keys(table_name: str, record: dict):
    primary_keys = table_primary_keys_dict[table_name]
    _ = primary_keys.__len__()
    for k in primary_keys:
        if k not in record.keys():
            _ -= 1
    if _ == 0:
        return False
    return True
