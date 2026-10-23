"""Tests for rate limiting."""

import pytest
from unittest.mock import AsyncMock, MagicMock
from fastapi import HTTPException

from app.auth.rate_limit import RateLimiter


class MockRedis:
    """Mock Redis client for testing."""

    def __init__(self) -> None:
        self.data: dict[str, int] = {}

    async def incr(self, key: str) -> int:
        self.data[key] = self.data.get(key, 0) + 1
        return self.data[key]

    async def expire(self, key: str, seconds: int) -> bool:
        return True

    async def get(self, key: str) -> str | None:
        value = self.data.get(key)
        return str(value) if value is not None else None


@pytest.fixture
def mock_redis() -> MockRedis:
    """Create mock Redis client."""
    return MockRedis()


@pytest.fixture
def rate_limiter(mock_redis: MockRedis) -> RateLimiter:
    """Create rate limiter with mock Redis."""
    return RateLimiter(
        redis_client=mock_redis,  # type: ignore
        requests_per_minute=5,
        requests_per_day=10,
    )


class TestRateLimiter:
    """Test suite for RateLimiter."""

    @pytest.mark.asyncio
    async def test_first_request_allowed(self, rate_limiter: RateLimiter) -> None:
        """First request should always be allowed."""
        # Should not raise
        await rate_limiter.check("user-1")

    @pytest.mark.asyncio
    async def test_requests_within_limit_allowed(self, rate_limiter: RateLimiter) -> None:
        """Multiple requests within limit should be allowed."""
        for _ in range(5):
            await rate_limiter.check("user-1")

    @pytest.mark.asyncio
    async def test_minute_limit_exceeded(self, rate_limiter: RateLimiter) -> None:
        """Exceeding per-minute limit should raise 429."""
        # Make 5 requests (the limit)
        for _ in range(5):
            await rate_limiter.check("user-1")

        # 6th request should fail
        with pytest.raises(HTTPException) as exc_info:
            await rate_limiter.check("user-1")

        assert exc_info.value.status_code == 429
        assert "per minute" in exc_info.value.detail

    @pytest.mark.asyncio
    async def test_day_limit_exceeded(self, rate_limiter: RateLimiter) -> None:
        """Exceeding daily limit should raise 429."""
        # Create limiter with higher minute limit, lower day limit
        limiter = RateLimiter(
            redis_client=MockRedis(),  # type: ignore
            requests_per_minute=100,  # High minute limit
            requests_per_day=10,
        )

        # Make 10 requests (the daily limit)
        for _ in range(10):
            await limiter.check("user-1")

        # 11th request should fail
        with pytest.raises(HTTPException) as exc_info:
            await limiter.check("user-1")

        assert exc_info.value.status_code == 429
        assert "daily" in exc_info.value.detail.lower()

    @pytest.mark.asyncio
    async def test_different_users_independent(self, rate_limiter: RateLimiter) -> None:
        """Rate limits should be per-user."""
        # User 1 makes 5 requests
        for _ in range(5):
            await rate_limiter.check("user-1")

        # User 1 is at limit, user 2 should still work
        await rate_limiter.check("user-2")

        # User 1 should fail
        with pytest.raises(HTTPException):
            await rate_limiter.check("user-1")

    @pytest.mark.asyncio
    async def test_get_usage(self, rate_limiter: RateLimiter) -> None:
        """get_usage should return correct stats."""
        # Make 3 requests
        for _ in range(3):
            await rate_limiter.check("user-1")

        usage = await rate_limiter.get_usage("user-1")

        assert usage["used_today"] == 3
        assert usage["limit_today"] == 10
        assert usage["remaining"] == 7

    @pytest.mark.asyncio
    async def test_get_usage_new_user(self, rate_limiter: RateLimiter) -> None:
        """get_usage for new user should show full quota."""
        usage = await rate_limiter.get_usage("new-user")

        assert usage["used_today"] == 0
        assert usage["limit_today"] == 10
        assert usage["remaining"] == 10
