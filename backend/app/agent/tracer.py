"""Structured JSON logging for agent operations."""

import json
import logging
from datetime import datetime
from typing import Any
from uuid import uuid4

# Configure structured JSON logging
logging.basicConfig(level=logging.INFO, format="%(message)s")
logger = logging.getLogger("nook.agent")


class AgentTracer:
    """
    Structured logging for agent operations.
    All logs are JSON for easy querying in Railway/production.
    """

    def __init__(self, user_id: str, conversation_id: str):
        self.user_id = user_id
        self.conversation_id = conversation_id
        self.turn_id = str(uuid4())
        self.start_time = datetime.utcnow()

    def _log(self, event: str, level: str = "info", **data: Any) -> None:
        """Emit a structured log entry."""
        log_entry = {
            "ts": datetime.utcnow().isoformat() + "Z",
            "event": event,
            "user_id": self.user_id,
            "conversation_id": self.conversation_id,
            "turn_id": self.turn_id,
            **data,
        }

        log_fn = getattr(logger, level, logger.info)
        log_fn(json.dumps(log_entry))

    def turn_started(self, message_preview: str) -> None:
        """Log turn start."""
        self._log("turn_started", message_preview=message_preview[:100])

    def model_request(self, model: str, input_tokens: int, tool_count: int) -> None:
        """Log model API request."""
        self._log(
            "model_request",
            model=model,
            input_tokens=input_tokens,
            tool_count=tool_count,
        )

    def model_response(
        self,
        output_tokens: int,
        latency_ms: int,
        tool_calls: list[str],
        finish_reason: str,
    ) -> None:
        """Log model API response."""
        self._log(
            "model_response",
            output_tokens=output_tokens,
            latency_ms=latency_ms,
            tool_calls=tool_calls,
            finish_reason=finish_reason,
        )

    def tool_dispatched(self, tool_name: str, request_id: str) -> None:
        """Log tool dispatch to client."""
        self._log("tool_dispatched", tool_name=tool_name, request_id=request_id)

    def tool_result(
        self, tool_name: str, request_id: str, success: bool, latency_ms: int
    ) -> None:
        """Log tool execution result from client."""
        self._log(
            "tool_result",
            tool_name=tool_name,
            request_id=request_id,
            success=success,
            latency_ms=latency_ms,
        )

    def safeguard_triggered(self, reason: str, tool_name: str | None = None) -> None:
        """Log when a safeguard blocks an action."""
        self._log(
            "safeguard_triggered",
            level="warning",
            reason=reason,
            tool_name=tool_name,
        )

    def turn_completed(self, iterations: int, total_tool_calls: int) -> None:
        """Log turn completion."""
        elapsed_ms = int((datetime.utcnow() - self.start_time).total_seconds() * 1000)
        self._log(
            "turn_completed",
            iterations=iterations,
            total_tool_calls=total_tool_calls,
            total_latency_ms=elapsed_ms,
        )

    def turn_failed(self, error_type: str, message: str) -> None:
        """Log turn failure."""
        elapsed_ms = int((datetime.utcnow() - self.start_time).total_seconds() * 1000)
        self._log(
            "turn_failed",
            level="error",
            error_type=error_type,
            error_message=message,
            total_latency_ms=elapsed_ms,
        )

    def error(self, error_type: str, message: str) -> None:
        """Log an error during processing."""
        self._log("error", level="error", error_type=error_type, error_message=message)
