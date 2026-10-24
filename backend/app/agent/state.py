"""Agent loop state definitions."""

from enum import Enum
from typing import Any

from pydantic import BaseModel, Field, field_serializer


class LoopState(str, Enum):
    """Current state of the agent loop."""

    REASONING = "reasoning"  # Waiting for model response
    AWAITING_TOOLS = "awaiting_tools"  # Tools dispatched to client
    SYNTHESIZING = "synthesizing"  # Final answer generation
    COMPLETED = "completed"  # Terminal success
    FAILED = "failed"  # Terminal error
    CANCELLED = "cancelled"  # User cancelled


class TurnState(BaseModel):
    """
    Turn state sent BY THE CLIENT with each request.
    Backend is stateless - iOS owns all state.
    """

    iteration: int = 0
    pending_tool_calls: list[dict[str, Any]] = Field(default_factory=list)
    completed_tool_results: list[dict[str, Any]] = Field(default_factory=list)
    executed_tool_ids: set[str] = Field(default_factory=set)  # Prevent duplicate mutations

    model_config = {"extra": "forbid"}

    @field_serializer("executed_tool_ids")
    @classmethod
    def serialize_executed_tool_ids(cls, v: set[str]) -> list[str]:
        """Convert set to list for JSON serialization."""
        return list(v)


class ChatRequest(BaseModel):
    """Everything the backend needs - sent with every request."""

    conversation_id: str
    message: str  # User's message (first request), or empty for tool result submissions
    conversation_history: list[dict[str, Any]] = Field(default_factory=list)  # Recent messages
    available_tools: list[dict[str, Any]] = Field(default_factory=list)  # Tool schemas
    turn_state: TurnState | None = None  # None for first request, populated after

    # Limits (can override defaults)
    max_iterations: int = 10
    max_duration_seconds: int = 120

    model_config = {"extra": "forbid"}


class ToolRequest(BaseModel):
    """Tool execution request sent to iOS app."""

    request_id: str
    tool_name: str
    arguments: dict[str, Any]
    requires_confirmation: bool = False
    confirmation_message: str | None = None


class ToolResponse(BaseModel):
    """Tool execution result from iOS app."""

    request_id: str
    success: bool
    result: str  # Text for model
    display_text: str  # Text for UI chip
    error: str | None = None
    citations: list[dict[str, Any]] = Field(default_factory=list)


class StreamEvent(BaseModel):
    """SSE event sent to iOS app."""

    event_type: str  # "token", "tool_request", "done", "error"
    data: dict[str, Any]

    def to_sse(self) -> str:
        """Format as SSE message."""
        import json

        return f"event: {self.event_type}\ndata: {json.dumps(self.data)}\n\n"
