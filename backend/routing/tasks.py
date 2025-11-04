from fastapi import APIRouter, Depends, HTTPException, Query
from backend.db.client import get_db
from backend.services.challenges import generate_plan

router = APIRouter(prefix="/tasks", tags=["tasks"])

