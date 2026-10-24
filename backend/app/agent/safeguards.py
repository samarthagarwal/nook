"""Agent safeguards - prevent dangerous tool sequences and enforce limits."""

from typing import Any


class AgentSafeguards:
    """Validates tool calls and enforces safety limits."""

    # Maximum iterations before forcing termination
    MAX_ITERATIONS = 10

    # Maximum tool calls in a single turn
    MAX_TOOL_CALLS_PER_TURN = 15

    # Maximum write tool calls in a single turn
    MAX_WRITE_TOOLS_PER_TURN = 5

    # Tool sequences that should be blocked
    BLOCKED_TOOL_SEQUENCES: set[tuple[str, str]] = {
        ("todos_delete", "todos_delete"),  # No bulk deletes in sequence
    }

    # Tools that modify data (writes)
    WRITE_TOOLS: set[str] = {
        "todos_create",
        "todos_update",
        "todos_delete",
        "todos_complete",
        "notes_save",
        "calendar_create",
        "reminders_create",
    }

    # Tools that require user confirmation
    CONFIRMATION_REQUIRED: set[str] = {
        "todos_delete",
    }

    def __init__(
        self,
        max_iterations: int | None = None,
        max_tool_calls: int | None = None,
        max_write_tools: int | None = None,
    ):
        self.max_iterations = max_iterations or self.MAX_ITERATIONS
        self.max_tool_calls = max_tool_calls or self.MAX_TOOL_CALLS_PER_TURN
        self.max_write_tools = max_write_tools or self.MAX_WRITE_TOOLS_PER_TURN

    def is_write_tool(self, tool_name: str) -> bool:
        """Check if a tool performs write operations."""
        return tool_name in self.WRITE_TOOLS or any(
            tool_name.endswith(suffix) for suffix in ("_create", "_delete", "_update", "_save")
        )

    def requires_confirmation(self, tool_name: str) -> bool:
        """Check if a tool requires user confirmation."""
        return tool_name in self.CONFIRMATION_REQUIRED

    def validate_tool_call(
        self,
        tool_name: str,
        arguments: dict[str, Any],
        history: list[str],
        executed_tool_ids: set[str],
    ) -> tuple[bool, str | None]:
        """
        Validate if a tool call should be allowed.

        Args:
            tool_name: Name of the tool to call
            arguments: Tool arguments
            history: List of previously called tool names this turn
            executed_tool_ids: Set of tool call IDs already executed

        Returns:
            (allowed, rejection_reason) - if not allowed, rejection_reason explains why
        """
        # Check blocked sequences
        if history:
            last_tool = history[-1]
            if (last_tool, tool_name) in self.BLOCKED_TOOL_SEQUENCES:
                return False, f"Blocked sequence: {last_tool} → {tool_name}"

        # Check total tool call limit
        if len(history) >= self.max_tool_calls:
            return False, f"Tool call limit reached ({self.max_tool_calls})"

        # Check write tool limit
        write_count = sum(1 for t in history if self.is_write_tool(t))
        if self.is_write_tool(tool_name) and write_count >= self.max_write_tools:
            return False, f"Write tool limit reached ({self.max_write_tools})"

        return True, None

    def validate_iteration(self, iteration: int) -> tuple[bool, str | None]:
        """
        Check if another iteration is allowed.

        Returns:
            (allowed, rejection_reason)
        """
        if iteration >= self.max_iterations:
            return False, f"Maximum iterations reached ({self.max_iterations})"
        return True, None
