from fastapi import FastAPI
from backend.db.client import get_db, close
from backend.db.indexes import create_indexes
from backend.services.authentication import router as authentication_router
from backend.services.challenges import router as challenges_router
from backend.services.gamification import router as gamification_router

app = FastAPI(title="SkillUp")

@app.on_event("startup")
async def on_startup():
    db = await get_db()
    await create_indexes(db)

@app.on_event("shutdown")
async def on_shutdown():
    await close()


app.include_router(authentication_router)
app.include_router(challenges_router)
app.include_router(gamification_router)
