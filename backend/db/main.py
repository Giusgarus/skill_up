from fastapi import FastAPI
from app.db.client import get_db, close_client
from app.db.indexes import ensure_indexes
from app.api.v1.users import router as users_router
from app.api.v1.tasks import router as tasks_router

app = FastAPI(title="SkillUp (Monolith)")

@app.on_event("startup")
async def on_startup():
    db = await get_db()        # crea client e pinga Mongo
    await ensure_indexes(db)   # idempotente

@app.on_event("shutdown")
async def on_shutdown():
    await close_client()

app.include_router(users_router)
app.include_router(tasks_router)
