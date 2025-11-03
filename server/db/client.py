from motor.motor_asyncio import AsyncIOMotorClient, AsyncIOMotorDatabase, AsyncIOMotorCollection

_client: AsyncIOMotorClient | None = None

def get_mongo_client() -> AsyncIOMotorClient | None:
    pass

def close_mongo_client() -> None:
    pass

def get_db(name: str | None = None) -> AsyncIOMotorDatabase | None:
    pass

def get_collection(name: str) -> AsyncIOMotorCollection | None:
    pass

async def ping() -> bool:
    pass
