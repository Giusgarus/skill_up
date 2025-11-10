import logging
import os
import sys


sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from contextlib import asynccontextmanager

from fastapi import FastAPI
import backend.db.client as client
from backend.db.database import create_indexes
from backend.services.authentication.server import router as authentication_router
from backend.services.challenges.server import router as challenges_router
from backend.services.gamification.server import router as gamification_router

@asynccontextmanager
async def lifespan(_: FastAPI):
    client.connect()
    db = client.get_db()
    if db is None:
        logging.warning("MongoDB connection not available; API will run without database.")
    else:
        create_indexes(db)
    try:
        yield
    finally:
        await client.close()

app = FastAPI(title = "SkillUp", lifespan=lifespan)

app.include_router(authentication_router)
app.include_router(challenges_router)
app.include_router(gamification_router)

if __name__ == "__main__":
    import uvicorn

    host = os.getenv("HOST", "0.0.0.0")
    port = int(os.getenv("PORT", "8000"))
    reload = os.getenv("RELOAD", "false").lower() in {"1", "true", "yes"}

    uvicorn.run("backend.main:app", host=host, port=port, reload=reload)
