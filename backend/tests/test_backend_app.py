import json
import sys
from datetime import datetime, timedelta
from pathlib import Path

import mongomock
import pytest
from email_validator import EmailNotValidError
from fastapi.testclient import TestClient
from pymongo import ReturnDocument


BACKEND_DIR = Path(__file__).resolve().parents[1]
PROJECT_ROOT = BACKEND_DIR.parent
for path in (PROJECT_ROOT, BACKEND_DIR):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

import backend.main as main  # noqa: E402
from backend.db import client as db_client  # noqa: E402
import backend.db.database as database  # noqa: E402
from backend.services.authentication import server as auth_server  # noqa: E402
from backend.services.challenges import server as challenges_server  # noqa: E402
import backend.utils.llm_interaction as llm_interaction  # noqa: E402


@pytest.fixture()
def backend_app(monkeypatch):
    mock_client = mongomock.MongoClient()
    mock_db = mock_client["skillup"]
    mock_db["leaderboard"].insert_one({"_id": "topK", "items": []})
    db_calls: list = []

    def fake_connect(reset: bool = False) -> None:
        if reset:
            mock_client.drop_database(mock_db.name)
        db_client._client = mock_client
        db_client._db = mock_db

    monkeypatch.setattr(db_client, "connect", fake_connect)
    monkeypatch.setattr(db_client, "get_db", lambda: mock_db)
    monkeypatch.setattr(db_client, "get_client", lambda: mock_client)
    monkeypatch.setattr(db_client, "ping", lambda: True)
    async def async_close():
        return None

    monkeypatch.setattr(db_client, "close", async_close)
    monkeypatch.setattr(database, "connect_to_db", lambda: mock_db)

    def fake_find_many(table_name: str, filters=None, projection=None):
        coll = mock_db[table_name]
        cursor = coll.find(filter=filters or {}, projection=projection)
        return list(cursor)

    monkeypatch.setattr(database, "find_many", fake_find_many)

    def fake_find_one_and_update(
        table_name: str,
        keys_dict,
        values_dict,
        projection=None,
        return_policy: ReturnDocument = ReturnDocument.BEFORE,
    ):
        coll = mock_db[table_name]
        coll.find_one_and_update(
            filter=keys_dict,
            update=values_dict,
            projection=projection,
            return_document=return_policy,
        )
        result_doc = coll.find_one(keys_dict, projection=projection)
        if result_doc is None and isinstance(values_dict, dict):
            updated_fields = set()
            for op in ("$set", "$unset", "$inc"):
                op_values = values_dict.get(op)
                if isinstance(op_values, dict):
                    updated_fields.update(op_values.keys())
            relaxed_filter = {k: v for k, v in keys_dict.items() if k not in updated_fields}
            result_doc = coll.find_one(relaxed_filter, projection=projection)
        db_calls.append({"table": table_name, "keys": keys_dict, "result": result_doc})
        return result_doc

    monkeypatch.setattr(database, "find_one_and_update", fake_find_one_and_update)
    monkeypatch.setattr(challenges_server, "db", database)
    assert challenges_server.db.find_one_and_update is fake_find_one_and_update

    llm_calls: list[dict] = []

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

    today = datetime.utcnow().date()

    score_map = {"easy": 10, "medium": 30, "hard": 50}

    def _build_tasks(prefix: str, difficulties: tuple[str, ...]):
        tasks = {}
        for idx, diff in enumerate(difficulties):
            tasks[(today + timedelta(days=idx)).isoformat()] = {
                "title": f"{prefix} Task {idx}",
                "description": f"{prefix} description {idx}",
                "difficulty": diff,
                "score": score_map.get(diff, 10),
            }
        return tasks

    def fake_llm_response(payload: dict):
        goal_text = payload.get("goal") or "goal"
        if "replan" in goal_text.lower() or "new" in goal_text.lower():
            diffs = ("hard", "medium")
            prefix = "Replan"
        else:
            diffs = ("easy", "medium")
            prefix = "Plan"
        llm_calls.append(payload)
        return {
            "status": True,
            "result": {
                "prompt": goal_text,
                "response": f"response for {goal_text}",
                "tasks": _build_tasks(prefix, diffs),
            },
        }

    monkeypatch.setattr(llm_interaction, "get_llm_response", fake_llm_response)

    with TestClient(main.app) as client:
        yield {"client": client, "db": mock_db, "llm_calls": llm_calls, "db_calls": db_calls}


def register_user(client: TestClient, username: str, password: str = "ValidPass1!") -> dict:
    response = client.post(
        "/services/auth/register",
        json={"username": username, "password": password, "email": f"{username}@example.com"},
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["status"] is True
    return body


def create_plan(client: TestClient, token: str, goal: str = "Build a weekly habit") -> dict:
    response = client.post("/services/challenges/prompt", json={"token": token, "goal": goal})
    assert response.status_code == 200, response.text
    return response.json()


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
    assert login_body["status"] is True
    assert login_body["token"] != register_payload["token"]

    user_doc = db["users"].find_one({"username": username})
    sessions = list(db["sessions"].find({"user_id": user_doc["user_id"]}))
    assert len(sessions) == 2

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


def test_duplicate_registration_and_email_conflict(backend_app):
    client = backend_app["client"]
    payload = {"username": "taken_user", "password": "ValidPass1!", "email": "taken@example.com"}

    first = client.post("/services/auth/register", json=payload)
    assert first.status_code == 200

    duplicate_user = client.post("/services/auth/register", json=payload)
    assert duplicate_user.status_code == 403
    assert duplicate_user.json()["detail"] == "User already exists"

    second_payload = {
        "username": "other_user",
        "password": "ValidPass1!",
        "email": "taken@example.com",
    }
    email_conflict = client.post("/services/auth/register", json=second_payload)
    assert email_conflict.status_code == 404
    assert email_conflict.json()["detail"] == "Email already in use"


def test_register_rejects_invalid_email_and_password(backend_app):
    client = backend_app["client"]
    response = client.post(
        "/services/auth/register",
        json={"username": "bad_email", "password": "ValidPass1!", "email": "not-an-email"},
    )
    assert response.status_code == 401
    assert response.json()["detail"].startswith("Invalid email")

    weak_password = client.post(
        "/services/auth/register",
        json={"username": "weak_user", "password": "weak", "email": "weak@example.com"},
    )
    assert weak_password.status_code == 402


def test_login_requires_valid_credentials(backend_app):
    client = backend_app["client"]
    response = client.post("/services/auth/login", json={"username": "", "password": ""})
    assert response.status_code == 400

    register_user(client, "login_user")
    bad_login = client.post(
        "/services/auth/login", json={"username": "login_user", "password": "WrongPass1!"}
    )
    assert bad_login.status_code == 401
    assert bad_login.json()["detail"] == "Invalid username or password"


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
    tokens = {doc["token"] for doc in db["sessions"].find({})}
    assert token_one in tokens and token_two in tokens
    assert len(tokens) == 3

    user_doc = db["users"].find_one({"username": username})
    sessions = list(db["sessions"].find({"user_id": user_doc["user_id"]}))
    assert len(sessions) == 3


def test_check_bearer_requires_token_and_rejects_mismatch(backend_app):
    client = backend_app["client"]
    username = "bearer_owner"
    register_user(client, username)
    login = client.post("/services/auth/login", json={"username": username, "password": "ValidPass1!"})
    token = login.json()["token"]

    missing_token = client.post("/services/auth/check_bearer", json={"username": username, "token": ""})
    assert missing_token.status_code == 400

    invalid = client.post("/services/auth/check_bearer", json={"username": "other_user", "token": token})
    assert invalid.status_code == 403
    assert invalid.json()["detail"] == "Mismatch user id, username"


def test_update_user_via_set_route(backend_app):
    client = backend_app["client"]
    db = backend_app["db"]
    username = "profile_owner"
    token = register_user(client, username)["token"]

    update_response = client.post(
        "/services/gathering/set", json={"token": token, "attribute": "name", "record": "Ada Smith! #1"}
    )
    assert update_response.status_code == 200
    assert update_response.json()["attribute"] == "name"
    updated_user = db["users"].find_one({"username": username})
    assert updated_user["name"] == "Ada Smith! #1"


def test_update_user_validation_errors(backend_app):
    client = backend_app["client"]
    token = register_user(client, "invalid_chars")["token"]

    unsupported = client.post(
        "/services/gathering/set",
        json={"token": token, "attribute": "non_existing_field", "record": "value"},
    )
    assert unsupported.status_code == 401

    invalid_token = client.post(
        "/services/gathering/set",
        json={"token": "bogus", "attribute": "name", "record": "Ignored"},
    )
    assert invalid_token.status_code == 400
    assert invalid_token.json()["detail"] == "Invalid or missing token"


def test_update_user_rejects_duplicate_username(backend_app):
    client = backend_app["client"]
    db = backend_app["db"]
    register_user(client, "first_user")
    second_token = register_user(client, "second_user")["token"]

    dup_username = client.post(
        "/services/gathering/set",
        json={"token": second_token, "attribute": "username", "record": "first_user"},
    )
    assert dup_username.status_code == 409
    assert dup_username.json()["detail"] == "Username already in use"
    assert db["users"].find_one({"username": "second_user"}) is not None


def test_get_user_allows_only_supported_attributes(backend_app):
    client = backend_app["client"]
    token = register_user(client, "getter")["token"]

    set_response = client.post(
        "/services/gathering/set",
        json={"token": token, "attribute": "name", "record": "Ada Lovelace"},
    )
    assert set_response.status_code == 200

    valid_get = client.post(
        "/services/gathering/get",
        json={"token": token, "attribute": "name "},  # trailing space should be stripped
    )
    assert valid_get.status_code == 200
    assert valid_get.json()["name"] == "Ada Lovelace"

    unsupported = client.post(
        "/services/gathering/get",
        json={"token": token, "attribute": "password_hash"},
    )
    assert unsupported.status_code == 401
    assert unsupported.json()["detail"] == "Unsupported attribute"


def test_get_interests_returns_labels(backend_app):
    client = backend_app["client"]
    token = register_user(client, "interest_owner")["token"]

    set_response = client.post(
        "/services/gathering/interests",
        json={"token": token, "interests": ["Health", "Career"]},
    )
    assert set_response.status_code == 200, set_response.text

    response = client.post(
        "/services/gathering/get",
        json={"token": token, "attribute": "interests_info"},
    )
    assert response.status_code == 200, response.text
    assert response.json()["interests_info"] == ["Health", "Career"]


def test_get_user_returns_medals_from_collection(backend_app):
    client = backend_app["client"]
    db = backend_app["db"]
    token = register_user(client, "medal_user")["token"]
    user_doc = db["users"].find_one({"username": "medal_user"})
    today = datetime.utcnow().date().isoformat()

    db["medals"].insert_many(
        [
            {"user_id": user_doc["user_id"], "timestamp": today, "medal": [{"grade": "S", "task_id": 0}]},
            {"user_id": user_doc["user_id"], "timestamp": "2024-01-02", "medal": []},
        ]
    )

    response = client.post(
        "/services/gathering/get",
        json={"token": token, "attribute": "medals"},
    )

    assert response.status_code == 200, response.text
    medals = response.json().get("medals", {})
    assert medals[today][0]["grade"] == "S"
    assert "2024-01-02" in medals


def test_prompt_endpoint_creates_plan_and_tasks(backend_app):
    client = backend_app["client"]
    db = backend_app["db"]
    llm_calls = backend_app["llm_calls"]
    username = "planner"
    token = register_user(client, username)["token"]

    response = create_plan(client, token, goal="Build a weekly study habit")
    assert response["status"] is True
    assert response["plan_id"] == 1
    assert len(response["tasks"]) == 2
    assert llm_calls[0]["goal"] == "Build a weekly study habit"

    user_doc = db["users"].find_one({"username": username})
    tasks = list(db["tasks"].find({"user_id": user_doc["user_id"], "plan_id": 1}))
    assert len(tasks) == 2
    assert all(task["difficulty"] in (1, 3, 5) for task in tasks)

    plan = db["plans"].find_one({"plan_id": 1})
    assert plan is not None
    assert plan["n_tasks"] == 2
    assert 1 in db["users"].find_one({"username": username})["active_plans"]
    assert db["users"].find_one({"username": username})["n_plans"] == 1


def test_plan_active_lists_tasks(backend_app):
    client = backend_app["client"]
    token = register_user(client, "active_user")["token"]
    create_plan(client, token)

    active = client.post("/services/challenges/plan/active", json={"token": token})
    assert active.status_code == 200
    body = active.json()
    assert body["status"] is True
    assert len(body["plans"]) == 1
    plan = body["plans"][0]
    assert plan["plan_id"] == 1
    assert len(plan["tasks_all_info"]) == 2
    assert all("title" in task for task in plan["tasks_all_info"])


def test_task_done_updates_score_plan_leaderboard_and_medals(backend_app):
    client = backend_app["client"]
    db = backend_app["db"]
    db_calls = backend_app["db_calls"]
    username = "task_player"
    token = register_user(client, username)["token"]
    create_plan(client, token)

    user_doc = db["users"].find_one({"username": username})
    assert (
        db["tasks"].count_documents(
            {"user_id": user_doc["user_id"], "plan_id": 1, "task_id": 0, "deleted": False}
        )
        == 1
    )

    response = client.post(
        "/services/challenges/task_done",
        json={"token": token, "plan_id": 1, "task_id": 0},
    )
    if response.status_code != 200:
        tasks_dump = list(db["tasks"].find({"plan_id": 1}))
        pytest.fail(f"task_done failed: {response.text} tasks={tasks_dump} calls={db_calls}")
    assert response.status_code == 200, response.text
    assert response.json()["status"] is True

    updated_user = db["users"].find_one({"username": username})
    assert updated_user["n_tasks_done"] == 1
    assert updated_user["score"] == 10

    leaderboard = db["leaderboard"].find_one({"_id": "topK"})
    assert leaderboard["items"][0] == {"username": username, "score": 10}

    task_doc = db["tasks"].find_one({"task_id": 0, "plan_id": 1})
    assert task_doc["completed_at"] is not None

    plan_doc = db["plans"].find_one({"plan_id": 1})
    assert plan_doc["n_tasks_done"] == 1
    assert plan_doc["completed_at"] is None

    medal_doc = db["medals"].find_one({"user_id": updated_user["user_id"]})
    assert medal_doc is not None
    assert medal_doc["medal"][0]["grade"] == "G"


def test_task_done_error_paths(backend_app):
    client = backend_app["client"]
    token = register_user(client, "missing_task_user")["token"]
    create_plan(client, token)

    invalid_token = client.post(
        "/services/challenges/task_done",
        json={"token": "bad", "plan_id": 1, "task_id": 0},
    )
    assert invalid_token.status_code == 401

    missing_task = client.post(
        "/services/challenges/task_done", json={"token": token, "plan_id": 99, "task_id": 999}
    )
    assert missing_task.status_code == 404


def test_report_stores_feedback_on_task(backend_app):
    client = backend_app["client"]
    db = backend_app["db"]
    token = register_user(client, "report_user")["token"]
    create_plan(client, token)

    report_text = "Wrapped up with some extra stretching"
    response = client.post(
        "/services/challenges/report",
        json={"token": token, "plan_id": 1, "task_id": 0, "report": report_text},
    )
    assert response.status_code == 200, response.text
    assert response.json()["status"] is True

    task_doc = db["tasks"].find_one({"plan_id": 1, "task_id": 0})
    assert task_doc["report"] == report_text
    other_task = db["tasks"].find_one({"plan_id": 1, "task_id": 1})
    assert other_task.get("report") is None


def test_report_requires_valid_session_and_existing_task(backend_app):
    client = backend_app["client"]
    db = backend_app["db"]
    token = register_user(client, "report_guard")["token"]
    create_plan(client, token)

    bad_session = client.post(
        "/services/challenges/report",
        json={"token": "invalid", "plan_id": 1, "task_id": 0, "report": "ignored"},
    )
    assert bad_session.status_code == 401
    assert bad_session.json()["detail"] == "Invalid or missing token"
    assert db["tasks"].find_one({"plan_id": 1, "task_id": 0}).get("report") is None

    missing_task = client.post(
        "/services/challenges/report",
        json={"token": token, "plan_id": 1, "task_id": 99, "report": "not found"},
    )
    assert missing_task.status_code == 503
    assert db["tasks"].find_one({"plan_id": 1, "task_id": 0}).get("report") is None


def test_task_undo_reverts_progress_and_leaderboard(backend_app):
    client = backend_app["client"]
    db = backend_app["db"]
    username = "undo_player"
    token = register_user(client, username)["token"]
    create_plan(client, token)

    assert client.post(
        "/services/challenges/task_done",
        json={"token": token, "plan_id": 1, "task_id": 0},
    ).status_code == 200
    assert client.post(
        "/services/challenges/task_done",
        json={"token": token, "plan_id": 1, "task_id": 1},
    ).status_code == 200

    plan_doc = db["plans"].find_one({"plan_id": 1})
    assert plan_doc["n_tasks_done"] == 2
    assert plan_doc["completed_at"] is not None
    assert db["users"].find_one({"username": username})["active_plans"] == []

    undo_resp = client.post(
        "/services/challenges/task_undo",
        json={"token": token, "plan_id": 1, "task_id": 1},
    )
    assert undo_resp.status_code == 200, undo_resp.text
    undo_body = undo_resp.json()
    assert undo_body["status"] is True
    assert undo_body["score"] == 10

    plan_doc = db["plans"].find_one({"plan_id": 1})
    assert plan_doc["n_tasks_done"] == 1
    assert plan_doc["completed_at"] is None

    task_doc = db["tasks"].find_one({"plan_id": 1, "task_id": 1})
    assert task_doc["completed_at"] is None

    user_doc = db["users"].find_one({"username": username})
    assert user_doc["n_tasks_done"] == 1
    assert user_doc["score"] == 10
    assert 1 in user_doc["active_plans"]

    medal_doc = db["medals"].find_one({"user_id": user_doc["user_id"]})
    if medal_doc:
        assert all(entry["task_id"] != 1 for entry in medal_doc.get("medal", []))

    leaderboard_doc = db["leaderboard"].find_one({"_id": "topK"})
    assert leaderboard_doc["items"][0] == {"username": username, "score": 10}


def test_task_undo_requires_completed_task(backend_app):
    client = backend_app["client"]
    token = register_user(client, "undo_missing_task_user")["token"]
    create_plan(client, token)

    undo_resp = client.post(
        "/services/challenges/task_undo", json={"token": token, "plan_id": 1, "task_id": 0}
    )
    assert undo_resp.status_code == 404


def test_leaderboard_endpoint_returns_sorted_scores(backend_app):
    client = backend_app["client"]
    db = backend_app["db"]

    token_low = register_user(client, "alpha")["token"]
    create_plan(client, token_low)
    assert client.post(
        "/services/challenges/task_done",
        json={"token": token_low, "plan_id": 1, "task_id": 0},
    ).status_code == 200

    token_high = register_user(client, "beta")["token"]
    create_plan(client, token_high)
    assert client.post(
        "/services/challenges/task_done",
        json={"token": token_high, "plan_id": 1, "task_id": 0},
    ).status_code == 200
    assert client.post(
        "/services/challenges/task_done",
        json={"token": token_high, "plan_id": 1, "task_id": 1},
    ).status_code == 200

    leaderboard_response = client.post(
        "/services/gamification/leaderboard", json={"token": token_low}
    )
    assert leaderboard_response.status_code == 200
    items = leaderboard_response.json()["leaderboard"]
    ordered = sorted(items, key=lambda entry: (-entry["score"], entry["username"]))
    assert ordered == [{"username": "beta", "score": 40}, {"username": "alpha", "score": 10}]

    leaderboard_doc = db["leaderboard"].find_one({"_id": "topK"})
    assert sorted(leaderboard_doc["items"], key=lambda entry: (-entry["score"], entry["username"])) == ordered


def test_plan_delete_marks_plan_and_active_list(backend_app):
    client = backend_app["client"]
    db = backend_app["db"]
    token = register_user(client, "deleter")["token"]
    create_plan(client, token)

    delete_resp = client.post("/services/challenges/plan/delete", json={"token": token, "plan_id": 1})
    assert delete_resp.status_code == 200
    assert delete_resp.json()["status"] is True

    user_doc = db["users"].find_one({"username": "deleter"})
    assert user_doc["active_plans"] == []

    plan_doc = db["plans"].find_one({"plan_id": 1})
    assert plan_doc["deleted"] is True


def test_retask_updates_task_and_prompt(backend_app):
    client = backend_app["client"]
    db = backend_app["db"]
    token = register_user(client, "retasker")["token"]
    create_plan(client, token, goal="retask original goal")

    original_prompts = db["plans"].find_one({"plan_id": 1})["prompts"]
    assert len(original_prompts) == 1

    new_goal = "new retask goal"
    resp = client.post(
        "/services/challenges/retask",
        json={"token": token, "plan_id": 1, "task_id": 0, "modification_reason": new_goal},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["status"] is True
    assert body["new_task"]["title"].startswith("Replan Task 0")
    assert body["new_task"]["score"] == 50
    assert body["new_prompt"].endswith(f"Task 0 modificated with: {new_goal}.")

    task_doc = db["tasks"].find_one({"plan_id": 1, "task_id": 0})
    assert task_doc["title"] == body["new_task"]["title"]
    assert task_doc["description"] == body["new_task"]["description"]
    assert task_doc["score"] == 50
    assert task_doc["completed_at"] is None

    plan_doc = db["plans"].find_one({"plan_id": 1})
    assert len(plan_doc["prompts"]) == len(original_prompts)
    assert plan_doc["prompts"][-1] == body["new_prompt"]


def test_retask_requires_existing_task(backend_app):
    client = backend_app["client"]
    token = register_user(client, "retask_missing")["token"]
    create_plan(client, token)

    resp = client.post(
        "/services/challenges/retask",
        json={"token": token, "plan_id": 99, "task_id": 0, "modification_reason": "new retask goal"},
    )
    assert resp.status_code == 404


def test_replan_replaces_tasks_and_resets_progress(backend_app):
    client = backend_app["client"]
    db = backend_app["db"]
    token = register_user(client, "replanner")["token"]
    create_plan(client, token, goal="original goal")

    replan_resp = client.post(
        "/services/challenges/prompt/replan",
        json={"token": token, "plan_id": 1, "new_goal": "new replan goal"},
    )
    assert replan_resp.status_code == 200
    body = replan_resp.json()
    assert body["status"] is True
    assert body["plan_id"] == 1
    assert len(body["tasks"]) == 2
    new_tasks = body["tasks"]
    assert all(task["task_id"] >= 2 for task in new_tasks)

    plan_doc = db["plans"].find_one({"plan_id": 1})
    assert plan_doc["n_replans"] == 1
    assert plan_doc["n_tasks_done"] == 0
    assert plan_doc["n_tasks"] == 2
    assert plan_doc["completed_at"] is None

    old_tasks = list(db["tasks"].find({"plan_id": 1, "task_id": {"$lt": 2}}))
    assert all(task["deleted"] is True for task in old_tasks)

    active_tasks = list(db["tasks"].find({"plan_id": 1, "deleted": False}))
    assert len(active_tasks) == 2
    assert set(task["task_id"] for task in active_tasks) == {2, 3}


def test_leaderboard_requires_authentication(backend_app):
    client = backend_app["client"]
    response = client.post("/services/gamification/leaderboard", json={"token": "invalid"})
    assert response.status_code == 401
