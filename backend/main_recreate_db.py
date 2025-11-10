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


def _recreate_database() -> None:
    """Drop the existing database and recreate required indexes."""
    client.connect(reset=True)
    db = client.get_db()
    if db is None:
        logging.warning("MongoDB connection not available; cannot recreate database.")
        return

    db_name = db.name
    mongo_client = db.client
    try:
        mongo_client.drop_database(db_name)
        logging.info("Dropped database '%s'.", db_name)
    except Exception as exc:
        logging.error("Failed to drop database '%s': %s", db_name, exc)
        return

    # Re-establish the client/db handles after dropping the database.
    client.connect(reset=True)
    db = client.get_db()
    if db is None:
        logging.warning("MongoDB connection not available after drop; cannot create indexes.")
        return

    create_indexes(db)
    logging.info("Recreated database '%s' with required indexes.", db_name)


@asynccontextmanager
async def lifespan(_: FastAPI):
    _recreate_database()
    try:
        yield
    finally:
        await client.close()


app = FastAPI(title="SkillUp (DB recreate)", lifespan=lifespan)

app.include_router(authentication_router)
app.include_router(challenges_router)
app.include_router(gamification_router)


if __name__ == "__main__":
    import uvicorn

    host = os.getenv("HOST", "0.0.0.0")
    port = int(os.getenv("PORT", "8000"))
    reload = os.getenv("RELOAD", "false").lower() in {"1", "true", "yes"}

    uvicorn.run("backend.main_recreate_db:app", host=host, port=port, reload=reload)
