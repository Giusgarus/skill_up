import json
import sys
from datetime import datetime, timedelta
from pathlib import Path

import mongomock
import pytest
from email_validator import EmailNotValidError
from fastapi.testclient import TestClient


BACKEND_DIR = Path(__file__).resolve().parents[1]
PROJECT_ROOT = BACKEND_DIR.parent
for path in (PROJECT_ROOT, BACKEND_DIR):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

import backend.main as main  # noqa: E402
from backend.db import client as db_client  # noqa: E402
from backend.services.authentication import server as auth_server  # noqa: E402
import backend.utils.llm_interaction as llm_interaction  # noqa: E402


@pytest.fixture()
def backend_app(monkeypatch):
    mock_client = mongomock.MongoClient()
    mock_db = mock_client["skillup"]

    def fake_connect(reset: bool = False) -> None:
        if reset:
            mock_client.drop_database(mock_db.name)
        db_client._client = mock_client
        db_client._db = mock_db

    async def fake_close() -> None:
        return None

    monkeypatch.setattr(db_client, "connect", fake_connect)
    monkeypatch.setattr(db_client, "get_db", lambda: mock_db)
    monkeypatch.setattr(db_client, "ping", lambda: True)
    monkeypatch.setattr(db_client, "close", fake_close)

    llm_calls: list[dict] = []

    class _FakeResponse:
        def __init__(self, body: dict):
            self._body = body
            self.status_code = 200
            self.text = json.dumps(body)

        def json(self):
            return self._body

    class _FakeSession:
        def post(self, url, json=None, timeout=None, headers=None):
            llm_calls.append(json or {})
            today = datetime.utcnow().date()
            body = {
                "challenges_count": 2,
                "challenges_list": [
                    {
                        "challenge_title": "Task 0",
                        "challenge_description": "Desc",
                        "difficulty": "easy",
                        "duration_minutes": 10,
                    },
                    {
                        "challenge_title": "Task 1",
                        "challenge_description": "Desc",
                        "difficulty": "easy",
                        "duration_minutes": 12,
                    },
                ],
            }
            return _FakeResponse(body)

    monkeypatch.setattr(llm_interaction, "get_session", lambda retries=2, backoff_factor=0.3: _FakeSession())

    mock_db["leaderboard"].insert_one({"_id": "topK", "items": []})

    class _EmailResult:
        def __init__(self, email: str):
            self.email = email

    def fake_validate_email(email: str, check_deliverability: bool = True):
        normalized = email.strip().lower()
        if (
            not normalized
            or "@" not in normalized
            or normalized.startswith("@")
            or normalized.endswith("@")
        ):
            raise EmailNotValidError("Invalid email format")
        local, domain = normalized.split("@", 1)
        if not local:
            raise EmailNotValidError("Invalid email format")
        if domain == "no-mx.test":
            raise EmailNotValidError("Domain does not have required MX records")
        return _EmailResult(normalized)

    monkeypatch.setattr(auth_server, "validate_email", fake_validate_email)

    with TestClient(main.app) as client:
        yield {"client": client, "db": mock_db, "llm_calls": llm_calls}


def register_user(client: TestClient, username: str, password: str = "ValidPass1!") -> dict:
    response = client.post(
        "/services/auth/register",
        json={"username": username, "password": password, "email": f"{username}@example.com"},
    )
    assert response.status_code == 200, response.text
    return response.json()


def seed_plan_and_task(db, user_id: str, plan_id: int, task_id: int, score: int) -> None:
    now = datetime.utcnow().isoformat()
    db["plans"].insert_one(
        {
            "plan_id": plan_id,
            "user_id": user_id,
            "n_tasks": 1,
            "n_tasks_done": 0,
            "responses": [],
            "prompts": [],
            "deleted": False,
            "difficulty": 1,
            "created_at": now,
            "expected_complete": now,
            "n_replans": 0,
            "tasks": [],
        }
    )
    db["tasks"].insert_one(
        {
            "task_id": task_id,
            "plan_id": plan_id,
            "user_id": user_id,
            "title": "t",
            "description": "d",
            "difficulty": 1,
            "score": score,
            "deadline_date": now,
            "completed_at": None,
            "deleted": False,
        }
    )


def test_register_login_and_check_bearer(backend_app):
    client = backend_app["client"]
    db = backend_app["db"]
    username = "user_auth"

    register_payload = register_user(client, username)
    login_response = client.post(
        "/services/auth/login", json={"username": username, "password": "ValidPass1!"}
    )
    assert login_response.status_code == 200, login_response.text
    login_body = login_response.json()
    assert login_body["username"] == username
    assert login_body["token"] != register_payload["token"]
    assert db["sessions"].count_documents({"token": login_body["token"]}) == 1

    bearer_response = client.post(
        "/services/auth/check_bearer", json={"username": username, "token": login_body["token"]}
    )
    assert bearer_response.status_code == 200
    assert bearer_response.json()["valid"] is True
    assert bearer_response.json()["username"] == username


def test_logout_removes_session_and_invalidates_token(backend_app):
    client = backend_app["client"]
    db = backend_app["db"]
    username = "logout_user"

    register_user(client, username)
    login = client.post("/services/auth/login", json={"username": username, "password": "ValidPass1!"})
    token = login.json()["token"]
    assert db["sessions"].count_documents({"token": token}) == 1

    logout_response = client.post("/services/auth/logout", json={"username": username, "token": token})
    assert logout_response.status_code == 200
    assert logout_response.json()["valid"] is True
    assert db["sessions"].count_documents({"token": token}) == 0

    bearer_after_logout = client.post(
        "/services/auth/check_bearer", json={"username": username, "token": token}
    )
    assert bearer_after_logout.status_code == 401


def test_logout_rejects_mismatched_username(backend_app):
    client = backend_app["client"]
    register_user(client, "logout_owner")
    token = client.post(
        "/services/auth/login", json={"username": "logout_owner", "password": "ValidPass1!"}
    ).json()["token"]

    response = client.post(
        "/services/auth/logout", json={"username": "someone_else", "token": token}
    )
    assert response.status_code == 403
    assert response.json()["detail"] == "Username does not match token owner"


def test_logout_rejects_invalid_token(backend_app):
    client = backend_app["client"]
    register_user(client, "invalid_token_user")

    response = client.post(
        "/services/auth/logout", json={"username": "invalid_token_user", "token": "bogus"}
    )
    assert response.status_code == 401


def test_duplicate_registration_fails(backend_app):
    client = backend_app["client"]
    payload = {"username": "taken_user", "password": "ValidPass1!", "email": "taken@example.com"}

    first = client.post("/services/auth/register", json=payload)
    assert first.status_code == 200

    duplicate = client.post("/services/auth/register", json=payload)
    assert duplicate.status_code == 403
    assert duplicate.json()["detail"] == "User already exists"


def test_register_rejects_weak_password(backend_app):
    client = backend_app["client"]
    response = client.post(
        "/services/auth/register",
        json={"username": "weak_user", "password": "weak", "email": "weak@example.com"},
    )
    assert response.status_code == 402


def test_register_rejects_invalid_email_format(backend_app):
    client = backend_app["client"]
    response = client.post(
        "/services/auth/register",
        json={"username": "bad_email", "password": "ValidPass1!", "email": "not-an-email"},
    )
    assert response.status_code == 401
    assert response.json()["detail"].startswith("Invalid email")


def test_register_rejects_email_without_mx_records(backend_app):
    client = backend_app["client"]
    response = client.post(
        "/services/auth/register",
        json={"username": "mx_user", "password": "ValidPass1!", "email": "user@no-mx.test"},
    )
    assert response.status_code == 401
    assert response.json()["detail"].startswith("Invalid email")


def test_register_rejects_duplicate_email(backend_app):
    client = backend_app["client"]
    payload = {"username": "first_email", "password": "ValidPass1!", "email": "dup@example.com"}
    response = client.post("/services/auth/register", json=payload)
    assert response.status_code == 200

    second_payload = {"username": "second_email", "password": "ValidPass1!", "email": "dup@example.com"}
    dup_response = client.post("/services/auth/register", json=second_payload)
    assert dup_response.status_code == 404


def test_login_requires_username_and_password(backend_app):
    client = backend_app["client"]
    response = client.post("/services/auth/login", json={"username": "", "password": ""})
    assert response.status_code == 400


def test_multiple_logins_issue_unique_tokens(backend_app):
    client = backend_app["client"]
    db = backend_app["db"]
    username = "multi_login"
    password = "ValidPass1!"
    register_user(client, username, password)

    first_login = client.post("/services/auth/login", json={"username": username, "password": password})
    second_login = client.post("/services/auth/login", json={"username": username, "password": password})
    assert first_login.status_code == 200
    assert second_login.status_code == 200

    token_one = first_login.json()["token"]
    token_two = second_login.json()["token"]
    assert token_one != token_two

    user_doc = db["users"].find_one({"username": username})
    sessions = list(db["sessions"].find({"user_id": user_doc["user_id"]}))
    assert len(sessions) >= 3  # register creates an initial session
    token_set = {session["token"] for session in sessions}
    assert token_one in token_set and token_two in token_set


def test_check_bearer_requires_token(backend_app):
    client = backend_app["client"]
    response = client.post("/services/auth/check_bearer", json={"username": "any", "token": ""})
    assert response.status_code == 400


def test_check_bearer_rejects_mismatched_username(backend_app):
    client = backend_app["client"]
    username = "bearer_owner"
    register_user(client, username)
    login = client.post("/services/auth/login", json={"username": username, "password": "ValidPass1!"})
    token = login.json()["token"]

    invalid = client.post("/services/auth/check_bearer", json={"username": "other_user", "token": token})
    assert invalid.status_code == 403


def test_update_user_respects_allowed_fields(backend_app):
    client = backend_app["client"]
    db = backend_app["db"]
    username = "profile_owner"
    token = register_user(client, username)["token"]

    update_response = client.post(
        "/services/challenges/set", json={"token": token, "attribute": "name", "record": "Ada"}
    )
    assert update_response.status_code == 200
    updated_user = db["users"].find_one({"username": username})
    assert updated_user["name"] == "Ada"

    invalid_response = client.post(
        "/services/challenges/set",
        json={"token": token, "attribute": "non_existing_field", "record": "value"},
    )
    assert invalid_response.status_code == 401


def test_update_user_accepts_spaces_and_symbols(backend_app):
    client = backend_app["client"]
    db = backend_app["db"]
    token = register_user(client, "invalid_chars")["token"]
    payload = {
        "token": token,
        "attribute": "name",
        "record": "Ada Smith! #1",
    }
    response = client.post(
        "/services/challenges/set",
        json=payload,
    )
    assert response.status_code == 200, response.json()
    stored = db["users"].find_one({"username": "invalid_chars"})
    assert stored["name"] == "Ada Smith! #1"


def test_update_user_rejects_invalid_token(backend_app):
    client = backend_app["client"]
    response = client.post(
        "/services/challenges/set",
        json={"token": "bogus", "attribute": "name", "record": "Ignored"},
    )
    assert response.status_code == 400


def test_task_done_updates_score_plan_and_leaderboard(backend_app):
    client = backend_app["client"]
    db = backend_app["db"]
    username = "task_player"
    token = register_user(client, username)["token"]
    user_doc = db["users"].find_one({"username": username})
    score_value = 75
    plan_id = 1
    task_id = 1
    seed_plan_and_task(db, user_doc["user_id"], plan_id=plan_id, task_id=task_id, score=score_value)

    response = client.post(
        "/services/challenges/task_done",
        json={"token": token, "plan_id": plan_id, "task_id": task_id, "medal_taken": "G"},
    )
    assert response.status_code == 200
    assert response.json()["status"] is True

    updated_user = db["users"].find_one({"username": username})
    assert updated_user["n_tasks_done"] == 1
    assert updated_user["score"] == score_value

    leaderboard = db["leaderboard"].find_one({"_id": "topK"})
    assert leaderboard["items"][0] == {"username": username, "score": score_value}

    task_doc = db["tasks"].find_one({"task_id": task_id, "user_id": user_doc["user_id"]})
    assert task_doc["completed_at"] is not None

    plan_doc = db["plans"].find_one({"plan_id": plan_id, "user_id": user_doc["user_id"]})
    assert plan_doc["n_tasks_done"] == 1


def test_task_done_rejects_invalid_token(backend_app):
    client = backend_app["client"]
    response = client.post(
        "/services/challenges/task_done",
        json={"token": "bad", "plan_id": 1, "task_id": 1},
    )
    assert response.status_code == 401


def test_task_done_errors_when_task_missing(backend_app):
    client = backend_app["client"]
    token = register_user(client, "missing_task_user")["token"]
    response = client.post(
        "/services/challenges/task_done", json={"token": token, "plan_id": 99, "task_id": 999}
    )
    assert response.status_code == 404


def test_task_done_requires_plan_id(backend_app):
    client = backend_app["client"]
    token = register_user(client, "no_plan_id")["token"]
    response = client.post(
        "/services/challenges/task_done",
        json={"token": token, "task_id": 1, "plan_id": None},
    )
    assert response.status_code in (402, 422)


def test_leaderboard_endpoint_returns_sorted_scores(backend_app):
    client = backend_app["client"]
    db = backend_app["db"]

    token_low = register_user(client, "alpha")["token"]
    user_low = db["users"].find_one({"username": "alpha"})
    seed_plan_and_task(db, user_low["user_id"], plan_id=10, task_id=10, score=15)
    assert (
        client.post(
            "/services/challenges/task_done",
            json={"token": token_low, "plan_id": 10, "task_id": 10},
        ).status_code
        == 200
    )

    token_high = register_user(client, "beta")["token"]
    user_high = db["users"].find_one({"username": "beta"})
    seed_plan_and_task(db, user_high["user_id"], plan_id=11, task_id=11, score=80)
    assert (
        client.post(
            "/services/challenges/task_done",
            json={"token": token_high, "plan_id": 11, "task_id": 11},
        ).status_code
        == 200
    )

    leaderboard_response = client.post(
        "/services/gamification/leaderboard", json={"token": token_low}
    )
    assert leaderboard_response.status_code == 200
    items = leaderboard_response.json()["leaderboard"]
    ordered = sorted(items, key=lambda entry: (-entry["score"], entry["username"]))
    assert ordered == [{"username": "beta", "score": 80}, {"username": "alpha", "score": 15}]


def test_leaderboard_trims_to_top_k(backend_app):
    client = backend_app["client"]
    db = backend_app["db"]

    total_users = 12
    for idx in range(total_users):
        username = f"user_{idx}"
        token = register_user(client, username)["token"]
        user_doc = db["users"].find_one({"username": username})
        score = (idx + 1) * 5
        seed_plan_and_task(db, user_doc["user_id"], plan_id=200 + idx, task_id=200 + idx, score=score)
        assert (
            client.post(
                "/services/challenges/task_done",
                json={"token": token, "plan_id": 200 + idx, "task_id": 200 + idx},
            ).status_code
            == 200
        )

    leaderboard = db["leaderboard"].find_one({"_id": "topK"})
    assert len(leaderboard["items"]) == 10
    usernames = [entry["username"] for entry in leaderboard["items"]]
    assert len(set(usernames)) == 10
    assert all(name.startswith("user_") for name in usernames)


def test_leaderboard_requires_authentication(backend_app):
    client = backend_app["client"]
    response = client.post("/services/gamification/leaderboard", json={"token": "invalid"})
    assert response.status_code == 401


def test_prompt_endpoint_creates_plan_and_tasks(backend_app):
    client = backend_app["client"]
    db = backend_app["db"]
    llm_calls = backend_app["llm_calls"]
    username = "planner"
    token = register_user(client, username)["token"]

    response = client.post(
        "/services/challenges/prompt",
        json={"token": token, "goal": "Build a weekly study habit"},
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["status"] is True
    assert body["plan_id"] == 1
    assert len(body["tasks"]) == 2
    assert len(llm_calls) == 1
    assert llm_calls[0]["goal"] == "Build a weekly study habit"

    tasks = list(db["tasks"].find({"user_id": db["users"].find_one({"username": username})["user_id"]}))
    assert len(tasks) == 2
    plan = db["plans"].find_one({"plan_id": 1})
    assert plan is not None


def test_prompt_endpoint_requires_valid_token(backend_app):
    client = backend_app["client"]
    response = client.post(
        "/services/challenges/prompt",
        json={"token": "invalid", "goal": "test"},
    )
    assert response.status_code == 401
