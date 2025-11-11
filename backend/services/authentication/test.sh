#!/bin/bash

# URL base del server FastAPI
BASE_URL="http://127.0.0.1:8000"

echo "🚀 Inizio test API FastAPI su $BASE_URL"
echo "----------------------------------------"

# === 1. Registrazione utente ===
echo "[1] Test: POST /users/register"
RESPONSE=$(curl -X POST "$BASE_URL/users/register" \
     -H "Content-Type: application/json" \
     -d '{"email": "test1@example.com", "password": "1234"}')
echo "\n$RESPONSE\n"
echo -e "\n----------------------------------------"

# === 2. Login (se implementato) ===
echo "[2] Test: POST /users/login"
RESPONSE=$(curl -X POST "$BASE_URL/users/login" \
     -H "Content-Type: application/json" \
     -d '{"email": "test1@example.com", "password": "1234"}')
echo "\n$RESPONSE\n"
echo -e "\n----------------------------------------"

# === 3. Creazione challenge (esempio) ===
echo "[3] Test: POST /challenges"
RESPONSE=$(curl -X POST "$BASE_URL/challenges" \
     -H "Content-Type: application/json" \
     -d '{"goal": "drink more water"}')
echo "\n$RESPONSE\n"
echo -e "\n----------------------------------------"

# === 4. Recupero challenge ===
echo "[4] Test: GET /challenges/today"
RESPONSE=$(curl "$BASE_URL/challenges/today")
echo "\n$RESPONSE\n"
echo -e "\n----------------------------------------"

# === 5. Leaderboard ===
echo "[5] Test: GET /leaderboard"
RESPONSE=$(curl "$BASE_URL/leaderboard")
echo "\n$RESPONSE\n"
echo -e "\n----------------------------------------"

echo "✅ Tutti i test terminati."
