"""Per-user rate limiting using Redis."""

from datetime import datetime

import redis.asyncio as redis
from fastapi import HTTPException

from app.config import get_settings

# Global Redis client
_redis_client: redis.Redis | None = None


async def init_redis() -> redis.Redis:
    """Initialize Redis connection. Call once at startup."""
    global _redis_client
    if _redis_client is None:
        settings = get_settings()
        _redis_client = redis.from_url(settings.redis_url, decode_responses=True)
    return _redis_client


async def get_rate_limiter() -> "RateLimiter":
    """Dependency to get rate limiter instance."""
    client = await init_redis()
    settings = get_settings()
    return RateLimiter(
        redis_client=client,
        requests_per_minute=settings.rate_limit_requests_per_minute,
        requests_per_day=settings.rate_limit_requests_per_day,
    )


class RateLimiter:
    """Per-user rate limiting. All requests require authentication."""

    def __init__(
        self,
        redis_client: redis.Redis,
        requests_per_minute: int = 20,
        requests_per_day: int = 500,
    ):
        self.redis = redis_client
        self.requests_per_minute = requests_per_minute
        self.requests_per_day = requests_per_day

    async def check(self, user_id: str) -> None:
        """
        Check rate limits for authenticated user.

        Raises:
            HTTPException 429 if rate limit exceeded
        """
        now = datetime.utcnow()
        minute_key = f"rate:{user_id}:min:{now.strftime('%Y%m%d%H%M')}"
        day_key = f"rate:{user_id}:day:{now.strftime('%Y%m%d')}"

        # Increment counters
        minute_count = await self.redis.incr(minute_key)
        await self.redis.expire(minute_key, 60)

        day_count = await self.redis.incr(day_key)
        await self.redis.expire(day_key, 86400)

        if minute_count > self.requests_per_minute:
            raise HTTPException(
                status_code=429,
                detail="Rate limit exceeded: too many requests per minute",
                headers={"Retry-After": "60"},
            )

        if day_count > self.requests_per_day:
            raise HTTPException(
                status_code=429,
                detail="Rate limit exceeded: daily quota exhausted",
                headers={"Retry-After": "3600"},
            )

    async def get_usage(self, user_id: str) -> dict:
        """Get current usage stats for user."""
        now = datetime.utcnow()
        day_key = f"rate:{user_id}:day:{now.strftime('%Y%m%d')}"
        count = int(await self.redis.get(day_key) or 0)
        return {
            "used_today": count,
            "limit_today": self.requests_per_day,
            "remaining": max(0, self.requests_per_day - count),
        }
