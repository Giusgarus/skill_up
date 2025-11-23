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
    "n_plans": "<int>",
    // Qui facciamo così, se il timestamp giorno esiste, sappiamo che quel giorno l'utente ha preso una medaglia. In caso esista, il task che ha fatto prendere la medaglia x è task_id.
    // Se vogliamo capire la streak, possiamo pre-creare i timestamp giorno delle medals, tanto è il piano della LLM quando fare i task o no, se il timestampp giorno esiste vuol dure che potevamo avere medaglie, quindi c'erano tasks, lo precreiamo, ma la list corrispondete non ha niente dentro, a questo punto si potevano guadagnare medaglie ma l'utente non l'ha presa. Ti torna ? Se non c'è il timestamp giorno vuol dire che non c'erano task il giorno x. A questo punto basta cercare se la caridnalità della lista tra l'ultimo timestamp e l'ultimo è almeno 1, quindi c'è almeno una medaglia. (con orologio ogni 24 ore) 
    "medals":
      {
        "timestamp_giorno": [{"task_id": "<string>", "medal": "B"|"S"|"G"|}]
      },
      ...
    ],
    "streak": "<int>",
    "score": "<int>",
    ...
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

### 1.2 `tasks`
```json
[
  {
    "task_id": "<string>",
    "plan_id": "<string>",
    "user_id": "<string>",
    "title": "<string>",
    "description": "<string>",
    "difficulty": "<int>",
    "score": "<int>",
    "deadline_date": "<ISO datetime UTC>",
    "completed_at": "<ISO datetime UTC>|null",
    "deleted": "<bool>"
  },
  .
  .
  .
]
```
**Indexes**
```python
tasks_collection.create_index(["task_id"], unique=True)
```

### 1.3 `plans`
```json
[
  {
    "plan_id": "<string>",
    "user_id": "<string>",
    "n_tasks": "<int>",
    "repsonses": ["json_i"],
    "prompts": ["string_i"],
    "deleted": "<bool>",
    "n_tasks_done": "<int>",
    "responses": ["response_i"],
    "prompts": ["prompt_i"],
    "created_at": "<ISO datetime UTC>",
    "expected_complete": "<ISO datetime UTC>", // Scadenza data dall'utente
    // Ci serve un task di un giorno X ? user_id -> prendo tutti i plan_id tale per cui tempo attuale compreso tra [created_at, expected_complete] dei plan che escono, da li prendo la lista tasks indicizzato dal dizionario per giorno. Possiamo anche mettere un campo finished plan true false e fare un filter volendo filtrare senza le date, non so quanto convenga.
    // Lista di task indicizzata per giorno iso, nella lista ogni task è un semplicemente il suo ID, tanto tutte le informazioni si trovano dentro la collezione tasks
    "n_replans": "<int>", // index of the current active plan (e.g. with 2 replans we have 3 objects in list and the one in position 2 is the active one)
    "tasks": [
        { // 1 object for each replan (position 0 the first plan generated)
          "<ISO datetime UTC>" : ["lista di task"],
          "<ISO datetime UTC>" : ["lista di task"],
          ...
        },
        {
          "<ISO datetime UTC>" : ["lista di task"],
          "<ISO datetime UTC>" : ["lista di task"],
          ...
        },
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
tasks_collection.create_index(["plan_id","user_id"], unique=True)
tasks_collection.create_index(["created_at","expected_complete"])
```

### 1.4 `sessions`
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

### 1.5 `leaderboard`
```json
[
  {
    "username": "<uuid-v4>",
    "score": "<uint>"
  },
  .
  .
  .
]
```
**Indexes**
```python
leaderboard_collection.create_index("username", unique=True)
```

---

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

