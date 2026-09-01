# AGENTS.md — Nook

Read this before writing code. Also read `README.md` (design spec), `design-tokens.json`,
`screens.json`, and `design/private_ai_product_brief.pdf` (product decisions).

## What this repo/bundle is
A **design handoff**, not a codebase. `design/Nook.dc.html` is an HTML/React prototype used to
communicate visual design, copy, and interaction. Do not port its markup. Recreate the screens in the
target platform.

## Target
SwiftUI, iOS 17+, iPhone only. Local inference via MLX Swift. SQLite + GRDB for chat/entity storage.
See brief §2 for the module boundaries — build them as separate types from the start:
`ModelRuntime`, `AgentSession`, `SkillManager`, `ToolRegistry`, `ContextAssembler`,
`KnowledgeEngine`, `MemoryEngine`, `MCPClient`, `NativeToolExecutor`.

## Non-negotiable design rules
1. Two-accent privacy system. `#2F5D8A` = on device. `#8C6239` = leaves the device. Filled dot vs.
   hollow ring. Never use either color decoratively.
2. Any outgoing network call from an MCP tool shows the **verbatim payload** before it is sent,
   including what is *not* being sent.
3. Skill permission toggles default to **off**. Installing grants nothing.
4. No metering of local inference anywhere in the UI.
5. Serif (Newsreader / New York) for headings, system sans for UI, mono (IBM Plex / SF Mono) for
   structural labels, file names, payloads, and status. Three roles, no drift.
6. Calm motion only: progress interpolation and sheet presentation. No springs, no scale, no glow.
7. Copy avoids ML jargon. Check `screens.json` for the approved string before inventing one.

## Definition of done for a screen
- Matches `screens.json` layout, tokens, and copy.
- Uses real safe-area insets, not the prototype's hard-coded 60–74pt top padding.
- Dynamic Type scales without clipping; 44pt minimum hit targets.
- Icons are SF Symbols per `screens.json.iconMap`, not the prototype's text glyphs.
- VoiceOver: privacy badges have text labels ("runs on device" / "sends data to GitHub"), not color alone.

## Do not
- Do not add features not in brief §11 (MVP scope). §11 "Explicitly defer" is a hard list.
- Do not introduce a design system, component library, or color beyond `design-tokens.json`.
- Do not implement JavaScript Skills (brief: CLOSED, out of MVP).
- Do not hand-draw complex SVG/illustration; imagery stays a placeholder until real assets arrive.
