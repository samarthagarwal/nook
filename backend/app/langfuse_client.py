"""Langfuse client for prompt management and tracing."""

import logging
from functools import lru_cache
from typing import Any

from langfuse import Langfuse

from app.config import get_settings

logger = logging.getLogger(__name__)

# Fallback prompt if Langfuse is not configured or fails
FALLBACK_SYSTEM_PROMPT = """You are Nook, a helpful AI assistant running on the user's iPhone.

You have access to tools. Examine the tool list provided with each request to see what's available.

TOOL USAGE:
- CHECK MULTIPLE SOURCES when appropriate. For questions like "when is the meeting?", check both saved notes AND calendar.
- USE TOOLS PROACTIVELY. Search the user's notes before saying you don't know something.
- When the user shares information worth remembering, offer to save it or create a task.
- For tasks and reminders, use the todos tools. Todos support due dates.
- Don't assume you lack a capability — check the tool list first.

RESPONSE STYLE:
- Be concise and helpful.
- Don't make up information — use tools to get real data.
- If a tool fails, explain what happened and suggest alternatives.

QUICK REPLIES:
At the end of your response, you may include 2-3 quick reply chips: <chip>Label</chip>
- Labels should be 1-3 words, actionable suggestions.
- Only include chips when they add value.
- Chips appear as tappable buttons; the label becomes the user's next message.
"""


@lru_cache
def get_langfuse_client() -> Langfuse | None:
    """Get cached Langfuse client instance."""
    settings = get_settings()
    
    if not settings.langfuse_public_key or not settings.langfuse_secret_key:
        logger.info("Langfuse not configured - using fallback prompt")
        return None
    
    try:
        return Langfuse(
            public_key=settings.langfuse_public_key,
            secret_key=settings.langfuse_secret_key,
            host=settings.langfuse_base_url,
        )
    except Exception as e:
        logger.error(f"Failed to initialize Langfuse client: {e}")
        return None


def get_system_prompt() -> str:
    """
    Fetch system prompt from Langfuse, with fallback to hardcoded prompt.
    
    Returns the system message content from the chat prompt.
    """
    settings = get_settings()
    client = get_langfuse_client()
    
    if not client:
        return FALLBACK_SYSTEM_PROMPT
    
    try:
        prompt = client.get_prompt(settings.langfuse_prompt_name, label="production")
        
        # For chat prompts, compile returns list of messages
        messages = prompt.compile()
        
        # Find the system message
        for msg in messages:
            if isinstance(msg, dict) and msg.get("role") == "system":
                return msg.get("content", FALLBACK_SYSTEM_PROMPT)
        
        # If no system message found, return the first message content
        if messages and isinstance(messages[0], dict):
            return messages[0].get("content", FALLBACK_SYSTEM_PROMPT)
        
        logger.warning(f"No system message found in prompt '{settings.langfuse_prompt_name}'")
        return FALLBACK_SYSTEM_PROMPT
        
    except Exception as e:
        logger.error(f"Failed to fetch prompt from Langfuse: {e}")
        return FALLBACK_SYSTEM_PROMPT


def create_trace(
    name: str,
    user_id: str,
    session_id: str | None = None,
    metadata: dict[str, Any] | None = None,
) -> Any:
    """
    Create a Langfuse trace for observability.
    
    Returns the trace object or None if Langfuse is not configured.
    """
    client = get_langfuse_client()
    
    if not client:
        return None
    
    try:
        return client.trace(
            name=name,
            user_id=user_id,
            session_id=session_id,
            metadata=metadata or {},
        )
    except Exception as e:
        logger.error(f"Failed to create Langfuse trace: {e}")
        return None


def flush_langfuse() -> None:
    """Flush any pending Langfuse events."""
    client = get_langfuse_client()
    if client:
        try:
            client.flush()
        except Exception as e:
            logger.error(f"Failed to flush Langfuse: {e}")
