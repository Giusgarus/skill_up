from fastapi import FastAPI
import backend.db.client as client
from backend.db.database import create_indexes
from backend.services.authentication.server import router as authentication_router
from backend.services.challenges.server import router as challenges_router
from backend.services.gamification.server import router as gamification_router
from backend.services.notifications.server import router as notifications_router

app = FastAPI(title="SkillUp")

@app.on_event("startup")
async def on_startup():
    db = await client.get_db()
    await create_indexes(db)

@app.on_event("shutdown")
async def on_shutdown():
    await client.close()


app.include_router(authentication_router)
app.include_router(challenges_router)
app.include_router(gamification_router)
app.include_router(notifications_router)
