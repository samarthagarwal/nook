"""FastAPI application entry point."""

import logging
from contextlib import asynccontextmanager
from typing import AsyncIterator

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.auth.firebase import init_firebase
from app.auth.rate_limit import init_redis
from app.config import get_settings
from app.routes import chat_router, health_router

# Configure logging
settings = get_settings()
logging.basicConfig(
    level=getattr(logging, settings.log_level.upper()),
    format="%(message)s",  # JSON logs - message contains the structured data
)
logger = logging.getLogger("nook")


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Application lifespan - startup and shutdown."""
    # Startup
    logger.info('{"event": "startup", "message": "Initializing Nook backend"}')

    init_firebase()
    logger.info('{"event": "startup", "message": "Firebase initialized"}')

    await init_redis()
    logger.info('{"event": "startup", "message": "Redis connected"}')

    yield

    # Shutdown
    logger.info('{"event": "shutdown", "message": "Nook backend shutting down"}')


# Create FastAPI app
app = FastAPI(
    title="Nook Backend",
    description="Agent orchestration service for Nook iOS app",
    version="0.1.0",
    lifespan=lifespan,
)

# CORS middleware - allow iOS app
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # In production, restrict to your app's domains
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include routers
app.include_router(health_router)
app.include_router(chat_router)


@app.get("/")
async def root() -> dict[str, str]:
    """Root endpoint - service info."""
    return {
        "service": "Nook Backend",
        "version": "0.1.0",
        "status": "running",
    }
