# Skill‑Up — Backend Specification (EN)
**Date:** 11/06/2025

Summary document.
MongoDB collections (“tables”) with indexes and **main logic** for **registration** and **login**.

---

## 1) MongoDB Collections & Indexes

### 1.1 `users`
```json
[
  {
    "user_id": "<uuid-v4>",
    "username": "<string>",
    "password_hash": "<base64(salt||scrypt_key)>",
    "email": "<string>",
    "n_tasks_done": "<int>",
    "sessions": [
      "token1": "<string>",
      ...,
      "tokenN": "<string>",
    ]
    "data": {
      "score": "<int>",
      ...
    }
  },
  .
  .
  .
]
```
**Indexes**
```python
user_collection.create_index("user_id", unique=True)
```

---

## 1.2 `tasks`
```json
[
  {
    "task_id": "<string>",
    "user_id": "<string>",
    "created_at": "<ISO datetime UTC>",
    "completed_at": "<ISO datetime UTC>|null",
    "title": "<string>",
    "score": "<int>"
  },
  .
  .
  .
]
```
**Indexes**
```python
tasks_collection.create_index(["task_id","user_id"], unique=True)
```

---

### 1.3 `sessions`
```json
[
  {
    "token": "<urlsafe random>",
    "user_id": "<uuid-v4>",
    "expires_at": "<ISO datetime UTC>"
  },
  ...
]
```
**Indexes**
```python
sessions_collection.create_index("token", unique=True)
```

---

### 1.4 `leaderboard`
```json
[
  {
    "user_id": "<uuid-v4>",
    "score": "<uint>"
  },
  .
  .
  .
]
```
**Indexes**
```python
leaderboard_collection.create_index("user_id", unique=True)
```

## 2) Main logic

2.1 Registration (`POST /register`)
1. **Input validation**  
   - `username` not empty and **unique**  
   - `password` compliant with policy: **≥ 8** characters, at least **1 uppercase letter**, **1 lowercase letter**, **1 number**  
   - the email saved in `email` field
2. **Password hash (scrypt)**  
   - `salt = os.urandom(32)`  
   - `key = hashlib.scrypt(password.encode(), salt=salt, n=2**14, r=8, p=8)`
   - Save `password_hash = base64(salt || key)`
3. **User creation**  
   - `user_id = str(uuid.uuid4())`  
   - Insert in `users`: `{ user_id, username, password_hash, email, ... }`
4. **Session creation**  
   - **Use** `generate_session(user_id)` → inserts a record with `token`, `user_id`, `created_at` (and optional `expires_at`) into `sessions`  
   - ** Response**: `{ "token": "<session-token>", ‘username’: "<username>" }`

### 2.2 Login (`POST /login`)
1. **Input validation**: `username`, `password` cannot be empty.  
2. **User lookup**: `user = users.find_one({"username": username})` → 401 if it doesn't exist.
3. **Password verification**:
- Decode `password_hash` → separate `salt` (first 32 bytes) and `stored_key`.  
   - `new_key = hashlib.scrypt(provided_password.encode(), salt=salt, n=2**14, r=8, p=8)`  
   - `secrets.compare_digest(new_key, stored_key)` → 401 if mismatch.  
4. **New session**: `token = generate_session(user["user_id"])`
5. **Response**: `{ "token": "<session-token>", "user_id": "<user_id>" }`

