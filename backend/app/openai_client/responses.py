"""OpenAI Responses API client for agent reasoning."""

import time
from typing import Any, AsyncIterator

from openai import AsyncOpenAI

from app.config import get_settings


class OpenAIClient:
    """Wrapper for OpenAI Responses API with streaming support."""

    def __init__(self, client: AsyncOpenAI, default_model: str):
        self.client = client
        self.default_model = default_model

    async def create_response(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]] | None = None,
        model: str | None = None,
        stream: bool = True,
    ) -> AsyncIterator[dict[str, Any]]:
        """
        Create a response using the OpenAI API with streaming.

        Yields events:
        - {"type": "token", "content": "..."}
        - {"type": "tool_call", "id": "...", "name": "...", "arguments": {...}}
        - {"type": "done", "content": "...", "usage": {...}}
        - {"type": "error", "message": "..."}
        """
        model = model or self.default_model
        start_time = time.time()

        try:
            kwargs: dict[str, Any] = {
                "model": model,
                "messages": messages,
                "stream": stream,
            }

            if tools:
                kwargs["tools"] = tools
                kwargs["tool_choice"] = "auto"
                # Some models (e.g., gpt-6-luna) don't support reasoning_effort with tools
                # Setting to 'none' ensures compatibility
                kwargs["reasoning_effort"] = "none"

            if stream:
                async for event in self._stream_response(**kwargs):
                    yield event
            else:
                response = await self.client.chat.completions.create(**kwargs)
                yield self._parse_non_streaming_response(response, start_time)

        except Exception as e:
            yield {"type": "error", "message": str(e)}

    async def _stream_response(self, **kwargs: Any) -> AsyncIterator[dict[str, Any]]:
        """Handle streaming response from OpenAI."""
        start_time = time.time()
        collected_content = ""
        collected_tool_calls: dict[int, dict[str, Any]] = {}
        finish_reason = None

        stream = await self.client.chat.completions.create(**kwargs)

        async for chunk in stream:
            delta = chunk.choices[0].delta if chunk.choices else None
            finish_reason = chunk.choices[0].finish_reason if chunk.choices else None

            if delta is None:
                continue

            # Handle content tokens
            if delta.content:
                collected_content += delta.content
                yield {"type": "token", "content": delta.content}

            # Handle tool calls
            if delta.tool_calls:
                for tool_call in delta.tool_calls:
                    idx = tool_call.index
                    if idx not in collected_tool_calls:
                        collected_tool_calls[idx] = {
                            "id": tool_call.id or "",
                            "name": "",
                            "arguments": "",
                        }

                    if tool_call.id:
                        collected_tool_calls[idx]["id"] = tool_call.id
                    if tool_call.function:
                        if tool_call.function.name:
                            collected_tool_calls[idx]["name"] = tool_call.function.name
                        if tool_call.function.arguments:
                            collected_tool_calls[idx]["arguments"] += (
                                tool_call.function.arguments
                            )

        # Emit collected tool calls
        for tool_call in collected_tool_calls.values():
            if tool_call["name"] and tool_call["arguments"]:
                import json

                try:
                    arguments = json.loads(tool_call["arguments"])
                except json.JSONDecodeError:
                    arguments = {}

                yield {
                    "type": "tool_call",
                    "id": tool_call["id"],
                    "name": tool_call["name"],
                    "arguments": arguments,
                }

        # Emit done event
        latency_ms = int((time.time() - start_time) * 1000)
        yield {
            "type": "done",
            "content": collected_content,
            "finish_reason": finish_reason or "stop",
            "latency_ms": latency_ms,
            "tool_call_count": len(collected_tool_calls),
        }

    def _parse_non_streaming_response(
        self, response: Any, start_time: float
    ) -> dict[str, Any]:
        """Parse non-streaming response."""
        choice = response.choices[0]
        message = choice.message

        result: dict[str, Any] = {
            "type": "done",
            "content": message.content or "",
            "finish_reason": choice.finish_reason or "stop",
            "latency_ms": int((time.time() - start_time) * 1000),
        }

        if message.tool_calls:
            result["tool_calls"] = [
                {
                    "id": tc.id,
                    "name": tc.function.name,
                    "arguments": tc.function.arguments,
                }
                for tc in message.tool_calls
            ]

        if response.usage:
            result["usage"] = {
                "prompt_tokens": response.usage.prompt_tokens,
                "completion_tokens": response.usage.completion_tokens,
                "total_tokens": response.usage.total_tokens,
            }

        return result

    def build_messages(
        self,
        system_prompt: str,
        conversation_history: list[dict[str, Any]],
        tool_results: list[dict[str, Any]] | None = None,
    ) -> list[dict[str, Any]]:
        """
        Build messages array for OpenAI API.

        Args:
            system_prompt: System instructions
            conversation_history: Previous messages
            tool_results: Results from tool executions to append
        """
        messages: list[dict[str, Any]] = [{"role": "system", "content": system_prompt}]

        # Add conversation history
        for msg in conversation_history:
            messages.append(msg)

        # Add tool results if any
        if tool_results:
            for result in tool_results:
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": result["tool_call_id"],
                        "content": result["content"],
                    }
                )

        return messages


def create_openai_client() -> OpenAIClient:
    """Create OpenAI client from settings."""
    settings = get_settings()
    client = AsyncOpenAI(api_key=settings.openai_api_key)
    return OpenAIClient(client=client, default_model=settings.default_model)
