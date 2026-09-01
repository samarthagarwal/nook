# Handoff: Nook — Private AI Workspace (iOS)

## Overview
Nook is an iOS-first private AI workspace: a downloadable local LLM/VLM plus Knowledge (local RAG),
Memory (cross-chat recall), Skills (portable instruction packages), native iOS tools, and MCP for
external services. Product promise: **Know. Remember. Act.** — with a clear, inspectable boundary
whenever data leaves the device.

Source of truth for product decisions: `design/private_ai_product_brief.pdf` (Sept 2026 synthesis).
This handoff covers the **design layer** for the MVP surfaces in that brief.

## About the design files
`design/Nook.dc.html` is a **design reference**, not production code. It is an HTML/React prototype
that demonstrates intended look, copy, and behavior. Open it directly in a browser (it needs
`support.js` and `ios-frame.jsx` beside it — keep the folder intact).

Your job is to **recreate these designs in the target codebase**. For this product the target is
**SwiftUI on iOS 17+**; the brief's architecture (ModelRuntime, AgentSession, SkillManager,
ToolRegistry, ContextAssembler, KnowledgeEngine, MemoryEngine, MCPClient, NativeToolExecutor) is the
intended shape. Do not port the HTML/React structure — map each screen to idiomatic SwiftUI views
using the tokens and specs below. If you are instead building a web or cross-platform target, use the
same tokens and screen specs and follow that codebase's existing patterns.

`design/ios-frame.jsx` is a **prototyping device bezel only** — it has no production equivalent.
Ignore it except to understand that the design canvas is a 402×874pt iPhone viewport.

## Fidelity
**High-fidelity.** Colors, type, spacing, radii, and copy are final-intent and should be matched
closely. Two deliberate exceptions:
- Images are striped placeholders (`repeating-linear-gradient`). Real screenshots/thumbnails go there.
- Icons are minimal geometric glyphs and text characters (`‹`, `+`, `↑`, `×`, `⚙`, `⌥`) — replace with
  SF Symbols. Suggested mapping is in `screens.json` under `iconMap`.

## Design tokens
Machine-readable: `design-tokens.json`. Summary:

### Color
| Token | Hex / value | Use |
|---|---|---|
| `paper` | `#F7F4EE` | Screen background |
| `surface` | `#FDFCF9` | Cards, sheets, inputs |
| `surfaceSunken` | `#F4F1EA` | Rows inside sheets, code blocks |
| `canvas` | `#EDE8DF` | Prototype page bg (not in app) |
| `ink` | `#1B1815` | Primary text, primary buttons |
| `inkOnDark` | `#FBF9F5` | Text on `ink` |
| `ink70` | `rgba(27,24,21,0.70)` | Body text in cards |
| `ink62` | `rgba(27,24,21,0.62)` | Secondary body |
| `ink55` | `rgba(27,24,21,0.55)` | Tertiary |
| `ink45` | `rgba(27,24,21,0.45)` | Meta, back links |
| `ink40` | `rgba(27,24,21,0.40)` | Section eyebrows, inactive tabs |
| `hairline` | `rgba(27,24,21,0.09)` | Card borders, dividers |
| `hairlineStrong` | `rgba(27,24,21,0.13)` | Input borders |
| `fill` | `rgba(27,24,21,0.06)` | Icon-button backgrounds |
| `toggleOff` | `rgba(27,24,21,0.14)` | Toggle track, off |
| `local` | `#2F5D8A` | **On-device** accent: dots, citation numbers, selected borders, local tool chips |
| `localSoft` | `rgba(47,93,138,0.10)` | Local chip/tag background |
| `external` | `#8C6239` | **Leaves the device** accent: hollow ring, external tool cards, indexing-in-progress |
| `externalSoft` | `rgba(140,98,57,0.05)` | External tool card background |
| `scrim` | `rgba(27,24,21,0.34)` | Sheet backdrop |

**The two-accent rule is the core of the design and must be preserved.** Blue `local` = executed on
device. Ochre `external` = data left, or is leaving, the device. External markers are drawn as a
**hollow 6px ring with a 1.5px border**; local markers as a **filled 5px dot**. Never mix them.

### Typography
- **Display / headings** — Newsreader (Google Fonts), weight 400, letter-spacing `-0.01em`.
  Sizes: 46/1.04 (onboarding hero), 34/1.08 (paywall, "You're set"), 32/1.0 (tab-root titles),
  30/1.12, 27/1.1, 26/1.12 (detail titles), 24/1.18 (sheet titles), 21/1.2, 19/1.2 (card titles).
  iOS substitute if you don't ship the webfont: **New York** (`.serif` design) at the same sizes.
- **UI / body** — system sans (`-apple-system`). 16/1 buttons (500), 15/1.62 assistant message body
  (400), 14.5/1.5 user bubble, 14–15/1.25 row titles (400–500), 13.5/1.55 explanatory body,
  12.5/1.45 card subtitles, 11.5/1.4 meta. SwiftUI: `.body`, `.subheadline`, `.footnote`, `.caption`.
- **Mono** — IBM Plex Mono (400/500). Used *structurally*, not decoratively: eyebrow labels
  (10px/500, `letter-spacing:.13em`, uppercase), badges (10–10.5px), file names (12.5–14px),
  payload and SKILL.md blocks (11.5px/1.75), status lines (10.5–11px). iOS substitute:
  **SF Mono** / `.monospaced`.

### Spacing, radius, elevation
- Spacing scale actually used: 3, 5, 6, 7, 8, 9, 10, 11, 12, 14, 16, 18, 20, 22, 26, 36, 44 pt.
- Screen horizontal padding: 18–22pt (tab roots 20, detail screens 18, paywall 22).
- Safe areas in the prototype are hard-coded: **top padding 60–74pt** (status bar + Dynamic Island),
  **bottom 30–44pt**. In SwiftUI use real safe-area insets instead.
- Radii: 6 (small mono tags), 8–9 (chips), 10–12 (rows, cards), 13–14 (primary buttons, cards),
  19–20 (input/pill), 22 (bottom sheets), 26 (toggle track), full (icon buttons).
- Shadows: cards `0 1px 2px rgba(27,24,21,.04)`; sheets `0 20px 50px rgba(27,24,21,.28)`;
  toast `0 12px 30px rgba(27,24,21,.25)`. Tab bar: `backdrop-filter: blur(14px)` over
  `rgba(247,244,238,.94)` → `.ultraThinMaterial` in SwiftUI.
- Toggle: 44×26 track, 20×20 white knob, 3pt inset. On = `local` for on-device grants,
  `external` for MCP tool grants.

## Information architecture
Five tabs (label-only, mono 10.5px, active = filled 5pt `ink` dot above the label):
**Chat · Knowledge · Skills · Connect · Memory**. Settings lives behind a gear on the Chat root;
Models lives inside Settings. Chat *detail* hides the tab bar (full-height conversation).

## Screens
Full per-screen spec — layout, every component, exact copy — is in `screens.json`.
Thirteen states, mapped to brief §11 (MVP scope) and §13 (IA):

1. `onboarding` — 4 steps: hero → model tier pick → download progress → "You're set". Human tiers
   (Fast / Balanced / Powerful) with size and one-line role; **never** quantization names.
2. `chatList` — recent chats, model badge ("Balanced · on device"), gear + new chat.
3. `chat` — streaming assistant text, on-device retrieval chip, external tool card, citation chips,
   Knowledge-scope line above the composer, attach sheet.
4. `citationSheet` — the retrieved passage highlighted on a striped page stand-in, with the line
   "Retrieved on device. The whole file was never put into the model's context."
5. `approvalSheet` — the external-call boundary. Verbatim outgoing payload in mono, including an
   explicit `not sent` block. Actions: Send once / Always allow this tool / Don't.
6. `knowledge` — collections with per-collection index status.
7. `collection` — documents with per-document extraction progress; route into a scoped chat.
8. `skills` — Built in / Imported / Yours groups, ON-OFF badges.
9. `skill` — full SKILL.md, "Wants access to" toggles all starting **off**, enable CTA.
10. `connections` — MCP servers, tool counts, URLs.
11. `server` — approval policy segmented control (Every call / Consequential / Never) + per-tool toggles.
12. `memory` — natural-language search, results with quoted source message, Open / Forget.
13. `models`, `settings`, `paywall`, `shareSheet`, `toast`.

## Interactions & behavior
- **Streaming**: assistant text reveals ~4 characters per 16ms tick (tunable). Citations attach
  **only on completion** — never mid-stream. Thinking state = three dots at 25/18/11% opacity.
- **Agent loop shown in the transcript**: user message → local retrieval chip → streamed answer →
  citations. With MCP: user message → approval sheet → external tool card → streamed answer.
- **Approval**: modal bottom sheet over a `scrim`, status bar stays visible (sheet z-index sits below
  the status bar). "Always allow" persists per tool and confirms with a toast.
- **Forget**: removes the derived memory item only; copy states the chat is untouched.
- **Transitions**: 0.2s linear on progress bars; sheets slide from the bottom; no other motion. This
  design is deliberately calm — do not add spring or scale animations.
- **Hover** states exist in the prototype for mouse only (border darkens to `rgba(27,24,21,.20–.24)`).
  On iOS, use standard press states instead.

## State
Prototype state, and the production equivalent:

| Prototype | Production owner |
|---|---|
| `screen`, `sheet` | Navigation stack / `.sheet` presentation |
| `msgs` (role: user / localTool / extTool / assistant) | `AgentSession` + Message table (brief §9) |
| `streaming`, `thinking` | `ModelRuntime` token stream |
| `tier` | `ModelRuntime` active model |
| `scope` (per-collection booleans) | Per-chat Knowledge scope → `KnowledgeEngine` |
| `grants` (per-Skill tool grants) | `SkillManager` permission store |
| `tools` (per-MCP-tool enable) + `policy` | `ToolRegistry` + MCP approval policy |
| `forgotten` | `MemoryEngine` derived-index deletion |
| `pro` | StoreKit non-consumable entitlement |

## Copy rules
Plain and calm; mainstream privacy-minded reader. Sentence case everywhere. Never surface RAG,
embeddings, GGUF, quantization, context windows, or "MCP" as jargon in primary UI — the words used are
Knowledge, Memory, Skills, Connections, tools, on device. Exact strings are in `screens.json`.

## Assets
None to license. Fonts: Newsreader + IBM Plex Mono (both SIL OFL) — or the New York / SF Mono
substitutes. All imagery in the prototype is a placeholder to be replaced.

## Files
- `design/Nook.dc.html` — the prototype (open in a browser; keep siblings)
- `design/support.js`, `design/ios-frame.jsx` — prototype runtime + device bezel (not production)
- `design/private_ai_product_brief.pdf` — product/architecture brief
- `design-tokens.json` — tokens, machine-readable
- `screens.json` — per-screen component and copy spec
- `AGENTS.md` — instructions for an agentic IDE (Cursor, Antigravity, Claude Code, Codex)
- `IMPLEMENTATION_PLAN.md` — suggested build order, from the brief's phases
