"""Agent orchestrator - manages the reasoning loop and tool dispatch."""

import asyncio
from typing import Any, AsyncIterator
from uuid import uuid4

from app.agent.safeguards import AgentSafeguards
from app.agent.state import ChatRequest, LoopState, StreamEvent, TurnState
from app.agent.tracer import AgentTracer
from app.config import get_settings
from app.langfuse_client import get_system_prompt, create_trace, flush_langfuse
from app.openai_client import OpenAIClient
from app.tools.schemas import ToolRequest


class AgentOrchestrator:
    """
    Orchestrates the agent loop: reasoning → tool dispatch → collect results → repeat.

    The backend is stateless - iOS sends full turn state with each request.
    This class handles a single turn (user message → assistant response).
    """

    def __init__(
        self,
        user_id: str,
        conversation_id: str,
        openai_client: OpenAIClient,
        safeguards: AgentSafeguards | None = None,
    ):
        self.user_id = user_id
        self.conversation_id = conversation_id
        self.openai_client = openai_client
        self.safeguards = safeguards or AgentSafeguards()
        self.tracer = AgentTracer(user_id, conversation_id)
        self.settings = get_settings()

    async def run(self, request: ChatRequest) -> AsyncIterator[str]:
        """
        Run the agent loop for a chat request.

        Yields SSE-formatted events:
        - event: token
        - event: tool_request
        - event: done
        - event: error
        """
        self.tracer.turn_started(request.message)

        # Initialize or restore turn state
        turn_state = request.turn_state or TurnState()
        state = LoopState.REASONING
        tool_history: list[str] = []
        total_tool_calls = 0

        try:
            while state not in (LoopState.COMPLETED, LoopState.FAILED, LoopState.CANCELLED):
                # Check iteration limit
                allowed, reason = self.safeguards.validate_iteration(turn_state.iteration)
                if not allowed:
                    self.tracer.safeguard_triggered(reason or "iteration limit")
                    # Force synthesis
                    state = LoopState.SYNTHESIZING
                    async for event in self._synthesize_response(request, turn_state):
                        yield event
                    state = LoopState.COMPLETED
                    break

                # Build messages for OpenAI
                messages = self._build_messages(request, turn_state)

                # Call OpenAI
                self.tracer.model_request(
                    model=self.settings.default_model,
                    input_tokens=self._estimate_tokens(messages),
                    tool_count=len(request.available_tools),
                )

                tool_calls_this_round: list[dict[str, Any]] = []
                content_buffer = ""

                async for event in self.openai_client.create_response(
                    messages=messages,
                    tools=request.available_tools if request.available_tools else None,
                ):
                    if event["type"] == "token":
                        content_buffer += event["content"]
                        print(f"[DEBUG] Streaming token: {repr(event['content'][:50] if len(event['content']) > 50 else event['content'])}")
                        yield StreamEvent(
                            event_type="token", data={"content": event["content"]}
                        ).to_sse()

                    elif event["type"] == "tool_call":
                        tool_calls_this_round.append(event)

                    elif event["type"] == "done":
                        self.tracer.model_response(
                            output_tokens=event.get("usage", {}).get("completion_tokens", 0),
                            latency_ms=event.get("latency_ms", 0),
                            tool_calls=[tc["name"] for tc in tool_calls_this_round],
                            finish_reason=event.get("finish_reason", "stop"),
                        )

                    elif event["type"] == "error":
                        self.tracer.error("openai_error", event["message"])
                        yield StreamEvent(
                            event_type="error", data={"message": event["message"]}
                        ).to_sse()
                        state = LoopState.FAILED
                        break

                # If we got tool calls, dispatch them
                if tool_calls_this_round and state != LoopState.FAILED:
                    state = LoopState.AWAITING_TOOLS
                    pending_tools: list[dict[str, Any]] = []

                    for tc in tool_calls_this_round:
                        tool_name = tc["name"]
                        tool_id = tc["id"]

                        # Check safeguards
                        allowed, reason = self.safeguards.validate_tool_call(
                            tool_name=tool_name,
                            arguments=tc["arguments"],
                            history=tool_history,
                            executed_tool_ids=turn_state.executed_tool_ids,
                        )

                        if not allowed:
                            self.tracer.safeguard_triggered(reason or "unknown", tool_name)
                            # Add failed result to turn state
                            turn_state.completed_tool_results.append({
                                "tool_call_id": tool_id,
                                "content": f"Tool call blocked: {reason}",
                                "success": False,
                            })
                            continue

                        # Check for duplicate
                        if tool_id in turn_state.executed_tool_ids:
                            continue

                        # Dispatch tool request
                        tool_request = ToolRequest(
                            request_id=tool_id,
                            tool_name=tool_name,
                            arguments=tc["arguments"],
                            requires_confirmation=self.safeguards.requires_confirmation(tool_name),
                            confirmation_message=f"Confirm: {tool_name}?" if self.safeguards.requires_confirmation(tool_name) else None,
                        )

                        self.tracer.tool_dispatched(tool_name, tool_id)
                        pending_tools.append({"id": tool_id, "name": tool_name})
                        tool_history.append(tool_name)
                        total_tool_calls += 1

                        yield StreamEvent(
                            event_type="tool_request",
                            data=tool_request.to_sse_data(),
                        ).to_sse()

                    # Update turn state for client
                    turn_state.pending_tool_calls = pending_tools
                    turn_state.iteration += 1

                    # Return control to client - they'll submit tool results and call us again
                    yield StreamEvent(
                        event_type="awaiting_tools",
                        data={
                            "turn_state": turn_state.model_dump(),
                            "pending_count": len(pending_tools),
                        },
                    ).to_sse()
                    return  # Exit - client will call back with tool results

                # No tool calls - we have a final response
                if content_buffer.strip():
                    state = LoopState.COMPLETED
                else:
                    # Empty response, try to synthesize
                    state = LoopState.SYNTHESIZING
                    async for event in self._synthesize_response(request, turn_state):
                        yield event
                    state = LoopState.COMPLETED

            # Turn completed
            self.tracer.turn_completed(
                iterations=turn_state.iteration,
                total_tool_calls=total_tool_calls,
            )
            print(f"[DEBUG] Sending done event, content_buffer length: {len(content_buffer)}")
            yield StreamEvent(event_type="done", data={"iterations": turn_state.iteration}).to_sse()

        except asyncio.CancelledError:
            self.tracer.turn_failed("cancelled", "Request was cancelled")
            yield StreamEvent(event_type="error", data={"message": "Cancelled"}).to_sse()
            raise

        except Exception as e:
            self.tracer.turn_failed("exception", str(e))
            yield StreamEvent(event_type="error", data={"message": str(e)}).to_sse()
            raise

    async def _synthesize_response(
        self, request: ChatRequest, turn_state: TurnState
    ) -> AsyncIterator[str]:
        """Generate a final response when tool phase is complete."""
        messages = self._build_messages(request, turn_state, synthesis_mode=True)

        async for event in self.openai_client.create_response(
            messages=messages,
            tools=None,  # No tools in synthesis mode
        ):
            if event["type"] == "token":
                yield StreamEvent(
                    event_type="token", data={"content": event["content"]}
                ).to_sse()

    def _build_messages(
        self,
        request: ChatRequest,
        turn_state: TurnState,
        synthesis_mode: bool = False,
    ) -> list[dict[str, Any]]:
        """Build messages array for OpenAI API."""
        system_prompt = get_system_prompt()
        messages: list[dict[str, Any]] = [{"role": "system", "content": system_prompt}]

        # Add conversation history
        for msg in request.conversation_history:
            messages.append(msg)

        # Add current user message if this is the first iteration
        if turn_state.iteration == 0 and request.message:
            messages.append({"role": "user", "content": request.message})

        # Add tool results from previous iterations
        if turn_state.completed_tool_results:
            # We need to add the assistant message with tool calls first
            # This is reconstructed from the tool results
            tool_calls_for_assistant: list[dict[str, Any]] = []
            for result in turn_state.completed_tool_results:
                tool_call_id = result.get("tool_call_id", str(uuid4()))
                tool_calls_for_assistant.append({
                    "id": tool_call_id,
                    "type": "function",
                    "function": {
                        "name": result.get("tool_name", "unknown"),
                        "arguments": "{}",
                    },
                })

            if tool_calls_for_assistant:
                messages.append({
                    "role": "assistant",
                    "content": None,
                    "tool_calls": tool_calls_for_assistant,
                })

                # Add tool results
                for result in turn_state.completed_tool_results:
                    messages.append({
                        "role": "tool",
                        "tool_call_id": result.get("tool_call_id", ""),
                        "content": result.get("content", ""),
                    })

        # Add synthesis instruction if in synthesis mode
        if synthesis_mode and turn_state.completed_tool_results:
            messages.append({
                "role": "user",
                "content": "Based on the tool results above, provide a helpful response to the user. Be concise.",
            })

        return messages

    def _estimate_tokens(self, messages: list[dict[str, Any]]) -> int:
        """Rough token estimate (4 chars ≈ 1 token)."""
        import json
        text = json.dumps(messages)
        return len(text) // 4
