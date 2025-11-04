import json
import pytest
from fastapi.testclient import TestClient
import mongomock

import server_mongo as server
from server.db.database import create as init_db

@pytest.fixture(scope="module")
def client():

    init_db()  # inject before TestClient so startup won't override
    with TestClient(server.app) as c:
        yield c


def test_register_success(client):
    payload = {
        "username": "Alice",
        "password": "StrongPass1",
        "user_info": {"prefs": {"level": 3}}
    }
    r = client.post("/register", json=payload)
    assert r.status_code == 201, r.text
    body = r.json()
    assert "id" in body and body["username"] == "Alice"


def test_register_duplicate_username(client):
    payload = {
        "username": "Bob",
        "password": "StrongPass1",
        "user_info": {"prefs": {"level": 1}}
    }
    r1 = client.post("/register", json=payload)
    assert r1.status_code == 201

    r2 = client.post("/register", json=payload)
    assert r2.status_code == 400
    assert r2.json()["detail"] == "User already exists"


@pytest.mark.parametrize("weak_pw", ["short", "nocaps123", "NOLOWER123", "NoDigits"])
def test_register_weak_passwords(client, weak_pw):
    payload = {
        "username": f"user_{weak_pw}",
        "password": weak_pw,
        "user_info": {"prefs": {"level": 2}}
    }
    r = client.post("/register", json=payload)
    assert r.status_code == 400
    assert "Password does not meet complexity" in r.json()["detail"]


def test_login_success(client):
    # Ensure the user exists
    reg = {
        "username": "Charlie",
        "password": "StrongPass9",
        "user_info": {"prefs": {"level": 4}}
    }
    r = client.post("/register", json=reg)
    assert r.status_code in (201, 400)  # user may already exist if re-run

    # Login
    r = client.post("/login", json={"username": "Charlie", "password": "StrongPass9"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert "token" in body and len(body["token"]) >= 32
    assert body["username"] == "Charlie"
    assert "id" in body


def test_login_invalid_password(client):
    # Register (idempotent)
    reg = {
        "username": "Dana",
        "password": "GoodPass2",
        "user_info": {"prefs": {"level": 5}}
    }
    r = client.post("/register", json=reg)
    assert r.status_code in (201, 400)

    # Wrong password
    r = client.post("/login", json={"username": "Dana", "password": "BadPass2"})
    assert r.status_code == 401
    assert r.json()["detail"] == "Invalid username or password"


def test_login_missing_user(client):
    r = client.post("/login", json={"username": "NoSuchUser", "password": "Whatever1"})
    assert r.status_code == 401
    assert r.json()["detail"] == "Invalid username or password"


def test_session_uniqueness_and_storage(client):
    # Make sure we can create multiple distinct sessions
    reg = {
        "username": "Eve",
        "password": "NicePass3",
        "user_info": {"prefs": {"level": 7}}
    }
    client.post("/register", json=reg)

    r1 = client.post("/login", json={"username": "Eve", "password": "NicePass3"})
    r2 = client.post("/login", json={"username": "Eve", "password": "NicePass3"})
    assert r1.status_code == 200 and r2.status_code == 200

    t1 = r1.json()["token"]
    t2 = r2.json()["token"]
    assert t1 != t2

    # Verify sessions saved in DB (using server's global collection)
    sess_col = server.sessions_collection
    docs = list(sess_col.find({"user_id": r1.json()["id"]}))
    assert len(docs) >= 2
    assert all("created_at" in d for d in docs)