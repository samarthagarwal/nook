"""Health check endpoint."""

from fastapi import APIRouter

router = APIRouter(tags=["health"])


@router.get("/health")
async def health_check() -> dict[str, str]:
    """
    Health check endpoint for Railway/container orchestration.

    Returns:
        Simple status object
    """
    return {"status": "healthy"}
