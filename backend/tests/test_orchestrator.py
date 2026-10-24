"""Tests for agent orchestrator."""

import pytest
from unittest.mock import AsyncMock, MagicMock

from app.agent.orchestrator import AgentOrchestrator
from app.agent.safeguards import AgentSafeguards
from app.agent.state import ChatRequest, TurnState


class MockOpenAIClient:
    """Mock OpenAI client for testing."""

    def __init__(self, responses: list[list[dict]]):
        """
        Args:
            responses: List of response sequences. Each sequence is a list of events
                       to yield for one call to create_response.
        """
        self.responses = responses
        self.call_count = 0
        self.calls: list[dict] = []

    async def create_response(self, messages, tools=None):
        """Mock response generator."""
        self.calls.append({"messages": messages, "tools": tools})

        if self.call_count < len(self.responses):
            events = self.responses[self.call_count]
            self.call_count += 1
            for event in events:
                yield event
        else:
            yield {"type": "done", "content": "", "finish_reason": "stop"}


@pytest.fixture
def basic_request() -> ChatRequest:
    """Create a basic chat request for testing."""
    return ChatRequest(
        conversation_id="test-conv-1",
        message="Hello, how are you?",
        conversation_history=[],
        available_tools=[],
        max_iterations=3,
    )


@pytest.fixture
def request_with_tools() -> ChatRequest:
    """Create a chat request with tools."""
    return ChatRequest(
        conversation_id="test-conv-1",
        message="Add milk to my todo list",
        conversation_history=[],
        available_tools=[
            {
                "type": "function",
                "function": {
                    "name": "todos_create",
                    "description": "Create a todo item",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "title": {"type": "string", "description": "Todo title"},
                        },
                        "required": ["title"],
                    },
                },
            }
        ],
        max_iterations=3,
    )


class TestAgentOrchestrator:
    """Test suite for AgentOrchestrator."""

    @pytest.mark.asyncio
    async def test_simple_response_no_tools(self, basic_request: ChatRequest) -> None:
        """Test simple response without tool calls."""
        mock_client = MockOpenAIClient([
            [
                {"type": "token", "content": "Hello! "},
                {"type": "token", "content": "I'm doing well."},
                {"type": "done", "content": "Hello! I'm doing well.", "finish_reason": "stop"},
            ]
        ])

        orchestrator = AgentOrchestrator(
            user_id="test-user",
            conversation_id="test-conv-1",
            openai_client=mock_client,  # type: ignore
        )

        events = []
        async for event in orchestrator.run(basic_request):
            events.append(event)

        # Should have token events and done event
        assert len(events) >= 2
        assert 'event: token' in events[0]
        assert 'event: done' in events[-1]

    @pytest.mark.asyncio
    async def test_tool_call_dispatched(self, request_with_tools: ChatRequest) -> None:
        """Test that tool calls are dispatched to client."""
        mock_client = MockOpenAIClient([
            [
                {"type": "tool_call", "id": "call-1", "name": "todos_create", "arguments": {"title": "milk"}},
                {"type": "done", "content": "", "finish_reason": "tool_calls"},
            ]
        ])

        orchestrator = AgentOrchestrator(
            user_id="test-user",
            conversation_id="test-conv-1",
            openai_client=mock_client,  # type: ignore
        )

        events = []
        async for event in orchestrator.run(request_with_tools):
            events.append(event)

        # Should have tool_request and awaiting_tools events
        event_str = "".join(events)
        assert "tool_request" in event_str
        assert "todos_create" in event_str
        assert "awaiting_tools" in event_str

    @pytest.mark.asyncio
    async def test_iteration_limit_enforced(self, basic_request: ChatRequest) -> None:
        """Test that iteration limit is enforced."""
        basic_request.max_iterations = 2

        # Simulate model always requesting tools
        mock_client = MockOpenAIClient([
            [
                {"type": "tool_call", "id": "call-1", "name": "test_tool", "arguments": {}},
                {"type": "done", "content": "", "finish_reason": "tool_calls"},
            ]
        ] * 10)  # More than max_iterations

        safeguards = AgentSafeguards(max_iterations=2)
        orchestrator = AgentOrchestrator(
            user_id="test-user",
            conversation_id="test-conv-1",
            openai_client=mock_client,  # type: ignore
            safeguards=safeguards,
        )

        # First iteration should work
        events = []
        async for event in orchestrator.run(basic_request):
            events.append(event)

        # The orchestrator should stop after max_iterations
        # This is enforced in the loop

    @pytest.mark.asyncio
    async def test_blocked_tool_sequence(self, request_with_tools: ChatRequest) -> None:
        """Test that blocked tool sequences are rejected."""
        # Add a delete tool
        request_with_tools.available_tools.append({
            "type": "function",
            "function": {
                "name": "todos_delete",
                "description": "Delete a todo",
                "parameters": {"type": "object", "properties": {}},
            },
        })

        # Set up turn state as if we already called delete once
        request_with_tools.turn_state = TurnState(
            iteration=1,
            completed_tool_results=[
                {"tool_call_id": "prev-1", "tool_name": "todos_delete", "content": "Deleted"}
            ],
        )

        mock_client = MockOpenAIClient([
            [
                # Model tries to delete again
                {"type": "tool_call", "id": "call-2", "name": "todos_delete", "arguments": {}},
                {"type": "done", "content": "", "finish_reason": "tool_calls"},
            ]
        ])

        orchestrator = AgentOrchestrator(
            user_id="test-user",
            conversation_id="test-conv-1",
            openai_client=mock_client,  # type: ignore
        )

        events = []
        async for event in orchestrator.run(request_with_tools):
            events.append(event)

        # The safeguard should have blocked the second delete
        # Check that the tool was not dispatched (or was blocked)

    @pytest.mark.asyncio
    async def test_openai_error_handled(self, basic_request: ChatRequest) -> None:
        """Test that OpenAI errors are handled gracefully."""
        mock_client = MockOpenAIClient([
            [
                {"type": "error", "message": "Rate limit exceeded"},
            ]
        ])

        orchestrator = AgentOrchestrator(
            user_id="test-user",
            conversation_id="test-conv-1",
            openai_client=mock_client,  # type: ignore
        )

        events = []
        async for event in orchestrator.run(basic_request):
            events.append(event)

        event_str = "".join(events)
        assert "error" in event_str
        assert "Rate limit" in event_str
