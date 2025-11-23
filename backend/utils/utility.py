table_primary_keys_dict = {
    # These are Lists of Strings
    "users": ["user_id", "username", "email"], 
    
    # This is a List containing one Tuple
    "tasks": [("task_id", "user_id", "plan_id")], 
    "plans": [("plan_id", "user_id")],
    "medals": [("user_id", "timestamp")],
    
    # These are Lists of Strings (parentheses do nothing here)
    "sessions": ["token"],
    "leaderboard": ["_id"],
    "device_tokens" : ["device_token", "user_id"],
}

def check_primary_keys(table_name: str, record: dict):
    # Use .get() to avoid crashing if table_name doesn't exist
    primary_keys_options = table_primary_keys_dict.get(table_name)
    
    if not primary_keys_options:
        return False

    for pk_option in primary_keys_options:
        # CASE 1: Composite Key (Tuple) -> e.g., ("task_id", "user_id")
        # We need ALL keys in the tuple to be present in the record
        if isinstance(pk_option, tuple):
            if all(key in record for key in pk_option):
                return True
        
        # CASE 2: Single Key (String) -> e.g., "user_id"
        # We just need this one key to be present
        elif isinstance(pk_option, str):
            if pk_option in record:
                return True
                
    return False
