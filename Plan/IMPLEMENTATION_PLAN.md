# Implementation plan

Ordered to the brief's §18 sequence, with the design surfaces each phase unlocks.

## Phase 1 — Prove local intelligence
SwiftUI chat shell · MLX model download manager · one text model + one VLM · streaming with
cancellation, memory-pressure and thermal handling.
**Design surfaces:** `onboarding` (all 4 steps), `chatList`, `chat` (streaming + thinking state),
`models`, `settings`.

## Phase 2 — Knowledge
Import/extraction · chunking (400–600 tokens, 50–100 overlap, respect headings) · embedding model ·
local vector search · FTS · `ContextAssembler` with explicit token accounting · citations.
**Design surfaces:** `knowledge`, `collection` (per-doc progress), citation chips, `citationSheet`,
composer scope line, `scopeSheet`.

## Phase 3 — Agent and tools
`AgentSession` loop · `AgentTool` protocol · `ToolRegistry` · structured tool-call parsing ·
permission/confirmation model · 2–3 native tools (calendar, reminders, date/time, location).
**Design surfaces:** the on-device retrieval chip in `chat`, native permission prompts.

## Phase 4 — Skills
`SkillManager` · SKILL.md parse/import · progressive disclosure (name + description first) ·
per-Skill tool and Knowledge grants · built-in Skills + personal Skill editor.
**Design surfaces:** `skills`, `skill` (SKILL.md view + grant toggles).

## Phase 5 — MCP
Swift MCP client · Streamable HTTP + header auth · tool discovery and schema adaptation · approval UX ·
execution through the existing `ToolRegistry`.
**Design surfaces:** `connections`, `server` (policy + per-tool toggles), `approvalSheet`,
external tool card in `chat`.

## Phase 6 — Memory and polish
Cross-chat semantic + lexical retrieval · conversation summaries · explicit previous-conversation
attachment · Share Extension · paywall.
**Design surfaces:** `memory` (search, provenance, Forget), `shareSheet`, `paywall`,
"A previous conversation" in the attach sheet.

## First milestone to demo (brief §12)
Download the recommended VLM → create "Project Alpha" Knowledge → ask "What are the biggest risks in
this project?" and get a grounded answer with page citations → attach a screenshot and ask whether it
matches the spec → ask for GitHub issues and cross the approval boundary. That is exactly demo steps
01–04 in the prototype's left-hand script.
