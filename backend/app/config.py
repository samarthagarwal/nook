"""Application configuration from environment variables."""

import json
from functools import lru_cache

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    """Application settings loaded from environment variables."""

    # OpenAI
    openai_api_key: str
    default_model: str = "gpt-4o"

    # Firebase (JSON string of service account)
    firebase_service_account: str

    # Redis
    redis_url: str = "redis://localhost:6379"

    # Langfuse (optional - falls back to hardcoded prompt if not set)
    langfuse_public_key: str = ""
    langfuse_secret_key: str = ""
    langfuse_base_url: str = "https://cloud.langfuse.com"
    langfuse_prompt_name: str = "nook/system-prompt"

    # Rate limiting
    rate_limit_requests_per_minute: int = 20
    rate_limit_requests_per_day: int = 500

    # Agent limits
    agent_max_iterations: int = 10
    agent_max_duration_seconds: int = 120

    # Logging
    log_level: str = "INFO"

    # Dev mode - skip auth for local testing
    skip_auth: bool = False

    model_config = {"env_file": ".env", "env_file_encoding": "utf-8"}

    @property
    def firebase_credentials(self) -> dict:
        """Parse Firebase service account JSON."""
        return json.loads(self.firebase_service_account)


@lru_cache
def get_settings() -> Settings:
    """Get cached settings instance."""
    return Settings()
