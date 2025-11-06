# Skill‑Up — Backend Specification (EN)
**Date:** 10/27/2025

Summary document.
MongoDB collections (“tables”) with indexes and **main logic** for **registration** and **login**.

---

## 1) MongoDB Collections & Indexes

### 1.1 `users`
```json
{
  “username”: “<string>”,
  “user_id”: “<uuid-v4>”,
  “password_hash”: “<base64(salt||scrypt_key)>”,
  “user_mail”: “<string>” 
}
```
**Indexes**
```python
user_collection.create_index(“username”, unique = True)
```

---

### 1.2 `sessions`
```json
{
  “token”: “<urlsafe random>”,
  “user_id”: “<uuid-v4>”,
  “expires_at”: “<ISO datetime UTC>”
}
```
**Indexes**
```python
sessions_collection.create_index(“token”, unique = True)
sessions_collection.create_index(“expires_at”, expireAfterSeconds = 24 HOURS)
```

---

### 1.3 `user_data`
```json
{
  “user_id”: “<uuid-v4>”,
  “info”: “<dictionary>”,
  “score”: “<int>”,
  "n_tasks_done": "<int>",
  “tasks”: {
    “YYYY-MM-DD”: [
      {
        “task_id”: “<string>”,
        “title”: “<string>”,
        “score”: 10,
        “done”: false,
        “completed_at”: null
      }
    ]
    , ...
  }
}
```
**Indexes**
```python
user_data_collection.create_index(“user_id”, unique = True)
```

---

### 1.4 `leaderboard`
```json
{
  “user_id”: “<uuid-v4>”,
  “score”: “<uint>”
}
```
**Indexes**
```python
leaderboard.create_index([(“score”, -1), (“user_id”, 1)])
leaderboard.create_index(“user_id”, unique = True)
```

## 2) Main logic

2.1 Registration (`POST /register`)
1. **Input validation**  
   - `username` not empty and **unique**  
   - `password` compliant with policy: **≥ 8** characters, at least **1 uppercase letter**, **1 lowercase letter**, **1 number**  
   - `email` saved in `user_mail` (or rename to `email`)
2. **Password hash (scrypt)**  
   - `salt = os.urandom(32)`  
   - `key = hashlib.scrypt(password.encode(), salt=salt, n=2**14, r=8, p=8)`  
   - Save `password_hash = base64(salt || key)`
3. **User creation**  
   - `user_id = str(uuid.uuid4())`  
   - Insert in `users`: `{ username, password_hash, user_id, user_mail }`  
   - Insert in `user_data`: `{ user_id, info: {}, score: 0, tasks: {} }`
4. **Session creation**  
   - **Use** `generate_session(user_id)` → inserts a record with `token`, `user_id`, `created_at` (and optional `expires_at`) into `sessions`  
   - ** Response**: `{ “token”: “<session-token>”, ‘username’: “<username>” }`

### 2.2 Login (`POST /login`)
1. **Input validation**: `username`, `password` cannot be empty.  
2. **User lookup**: `user = users.find_one({“username”: username})` → 401 if it doesn't exist.
3. **Password verification**:
- Decode `password_hash` → separate `salt` (first 32 bytes) and `stored_key`.  
   - `new_key = hashlib.scrypt(provided_password.encode(), salt=salt, n=2**14, r=8, p=8)`  
   - `secrets.compare_digest(new_key, stored_key)` → 401 if mismatch.  
4. **New session**: `token = generate_session(user[“user_id”])`
5. **Response**: `{ “token”: “<session-token>”, ‘username’: “<username>” }`

