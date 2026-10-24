"""Chat API endpoint with SSE streaming."""

from typing import Any

from fastapi import APIRouter, Depends, HTTPException
from sse_starlette.sse import EventSourceResponse

from app.agent.orchestrator import AgentOrchestrator
from app.agent.safeguards import AgentSafeguards
from app.agent.state import ChatRequest
from app.auth import RateLimiter, get_current_user, get_rate_limiter
from app.openai_client import create_openai_client
from app.tools.schemas import ToolResponse

router = APIRouter(prefix="/chat", tags=["chat"])


@router.post("")
async def chat(
    request: ChatRequest,
    user: dict[str, Any] = Depends(get_current_user),
    rate_limiter: RateLimiter = Depends(get_rate_limiter),
) -> EventSourceResponse:
    """
    Main chat endpoint. Streams SSE events to the client.

    Events:
    - token: Assistant response token
    - tool_request: Tool to execute on client
    - awaiting_tools: Paused waiting for tool results
    - done: Conversation turn complete
    - error: Something went wrong

    The client should:
    1. Stream tokens to UI
    2. When tool_request arrives, execute locally and call POST /chat with tool result
    3. When done arrives, turn is complete
    """
    # Check rate limits
    await rate_limiter.check(user["uid"])

    # Create orchestrator
    openai_client = create_openai_client()
    safeguards = AgentSafeguards(
        max_iterations=request.max_iterations,
        max_tool_calls=15,
        max_write_tools=5,
    )

    orchestrator = AgentOrchestrator(
        user_id=user["uid"],
        conversation_id=request.conversation_id,
        openai_client=openai_client,
        safeguards=safeguards,
    )

    async def event_generator():
        """Generate SSE events from orchestrator."""
        async for event in orchestrator.run(request):
            # Pass pre-formatted SSE string directly
            yield event

    # Use raw Response for pre-formatted SSE
    from starlette.responses import StreamingResponse

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",  # Disable nginx buffering
        },
    )


@router.post("/{conversation_id}/tool-result")
async def submit_tool_result(
    conversation_id: str,
    result: ToolResponse,
    user: dict[str, Any] = Depends(get_current_user),
) -> dict[str, str]:
    """
    Submit a tool execution result.

    Note: In the stateless architecture, this endpoint just validates the result.
    The client should then call POST /chat again with the updated turn_state
    that includes this tool result.
    """
    # Validate user owns this conversation (would check against DB in production)
    # For now, just acknowledge receipt

    if not result.request_id:
        raise HTTPException(status_code=400, detail="request_id is required")

    return {
        "status": "received",
        "request_id": result.request_id,
        "message": "Include this result in turn_state.completed_tool_results when calling /chat again",
    }


@router.get("/usage")
async def get_usage(
    user: dict[str, Any] = Depends(get_current_user),
    rate_limiter: RateLimiter = Depends(get_rate_limiter),
) -> dict[str, Any]:
    """
    Get current usage stats for the authenticated user.

    Returns:
        Usage statistics including remaining quota
    """
    return await rate_limiter.get_usage(user["uid"])
