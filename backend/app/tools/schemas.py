"""Tool request/response schemas for iOS communication."""

from typing import Any

from pydantic import BaseModel, Field


class ToolRequest(BaseModel):
    """Tool execution request sent to iOS app via SSE."""

    request_id: str
    tool_name: str
    arguments: dict[str, Any] = Field(default_factory=dict)
    requires_confirmation: bool = False
    confirmation_message: str | None = None

    def to_sse_data(self) -> dict[str, Any]:
        """Convert to SSE event data."""
        data: dict[str, Any] = {
            "request_id": self.request_id,
            "tool_name": self.tool_name,
            "arguments": self.arguments,
        }
        if self.requires_confirmation:
            data["requires_confirmation"] = True
            if self.confirmation_message:
                data["confirmation_message"] = self.confirmation_message
        return data


class ToolResponse(BaseModel):
    """Tool execution result from iOS app."""

    request_id: str
    success: bool
    result: str  # Text for model
    display_text: str  # Text for UI chip
    error: str | None = None
    citations: list[dict[str, Any]] = Field(default_factory=list)

    def to_tool_message(self, tool_call_id: str) -> dict[str, Any]:
        """Convert to OpenAI tool message format."""
        content = self.result if self.success else f"Error: {self.error or self.result}"
        return {
            "tool_call_id": tool_call_id,
            "content": content,
        }


class ToolSchema(BaseModel):
    """Tool schema as sent from iOS app (OpenAI function format)."""

    type: str = "function"
    function: dict[str, Any]

    @property
    def name(self) -> str:
        """Get tool name from function definition."""
        return self.function.get("name", "")

    @property
    def description(self) -> str:
        """Get tool description."""
        return self.function.get("description", "")
