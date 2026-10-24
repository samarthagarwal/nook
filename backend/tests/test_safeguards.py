"""Tests for agent safeguards."""

import pytest

from app.agent.safeguards import AgentSafeguards


class TestAgentSafeguards:
    """Test suite for AgentSafeguards."""

    def setup_method(self) -> None:
        """Set up test fixtures."""
        self.safeguards = AgentSafeguards()

    def test_is_write_tool_known_tools(self) -> None:
        """Known write tools should be identified."""
        assert self.safeguards.is_write_tool("todos_create") is True
        assert self.safeguards.is_write_tool("todos_delete") is True
        assert self.safeguards.is_write_tool("notes_save") is True

    def test_is_write_tool_read_tools(self) -> None:
        """Read-only tools should not be identified as write tools."""
        assert self.safeguards.is_write_tool("todos_list") is False
        assert self.safeguards.is_write_tool("memory_search") is False
        assert self.safeguards.is_write_tool("calendar_search") is False

    def test_is_write_tool_suffix_detection(self) -> None:
        """Tools with write suffixes should be detected."""
        assert self.safeguards.is_write_tool("custom_create") is True
        assert self.safeguards.is_write_tool("custom_delete") is True
        assert self.safeguards.is_write_tool("custom_update") is True
        assert self.safeguards.is_write_tool("custom_save") is True

    def test_requires_confirmation(self) -> None:
        """Destructive tools should require confirmation."""
        assert self.safeguards.requires_confirmation("todos_delete") is True
        assert self.safeguards.requires_confirmation("todos_create") is False
        assert self.safeguards.requires_confirmation("todos_list") is False

    def test_validate_tool_call_allowed(self) -> None:
        """Normal tool calls should be allowed."""
        allowed, reason = self.safeguards.validate_tool_call(
            tool_name="todos_create",
            arguments={"title": "Test"},
            history=[],
            executed_tool_ids=set(),
        )
        assert allowed is True
        assert reason is None

    def test_validate_tool_call_blocked_sequence(self) -> None:
        """Blocked sequences should be rejected."""
        allowed, reason = self.safeguards.validate_tool_call(
            tool_name="todos_delete",
            arguments={"id": "2"},
            history=["todos_delete"],  # Already deleted one
            executed_tool_ids=set(),
        )
        assert allowed is False
        assert "Blocked sequence" in (reason or "")

    def test_validate_tool_call_limit_exceeded(self) -> None:
        """Tool call limit should be enforced."""
        safeguards = AgentSafeguards(max_tool_calls=2)

        allowed, reason = safeguards.validate_tool_call(
            tool_name="todos_list",
            arguments={},
            history=["todos_list", "memory_search"],  # Already 2 calls
            executed_tool_ids=set(),
        )
        assert allowed is False
        assert "limit reached" in (reason or "").lower()

    def test_validate_tool_call_write_limit_exceeded(self) -> None:
        """Write tool limit should be enforced."""
        safeguards = AgentSafeguards(max_write_tools=2)

        allowed, reason = safeguards.validate_tool_call(
            tool_name="todos_create",
            arguments={"title": "Third"},
            history=["todos_create", "notes_save"],  # Already 2 writes
            executed_tool_ids=set(),
        )
        assert allowed is False
        assert "Write tool limit" in (reason or "")

    def test_validate_iteration_allowed(self) -> None:
        """Iterations within limit should be allowed."""
        allowed, reason = self.safeguards.validate_iteration(0)
        assert allowed is True
        assert reason is None

        allowed, reason = self.safeguards.validate_iteration(9)
        assert allowed is True

    def test_validate_iteration_exceeded(self) -> None:
        """Iterations beyond limit should be rejected."""
        allowed, reason = self.safeguards.validate_iteration(10)
        assert allowed is False
        assert "Maximum iterations" in (reason or "")

    def test_custom_limits(self) -> None:
        """Custom limits should be respected."""
        safeguards = AgentSafeguards(
            max_iterations=5,
            max_tool_calls=3,
            max_write_tools=1,
        )

        assert safeguards.max_iterations == 5
        assert safeguards.max_tool_calls == 3
        assert safeguards.max_write_tools == 1

        allowed, _ = safeguards.validate_iteration(5)
        assert allowed is False

        allowed, _ = safeguards.validate_iteration(4)
        assert allowed is True
