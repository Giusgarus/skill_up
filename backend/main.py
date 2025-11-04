from fastapi import FastAPI
from backend.db.client import get_db, close_client
from backend.db.indexes import create_indexes
from backend.routing.users import router as users_router
from backend.routing.tasks import router as tasks_router

app = FastAPI(title="SkillUp")

@app.on_event("startup")
async def on_startup():
    db = await get_db()
    await create_indexes(db)

@app.on_event("shutdown")
async def on_shutdown():
    await close_client()


app.include_router(users_router)
app.include_router(tasks_router)
