# Plan B V3 — Gaviero Remote mobile app (new repo)

> **Copy this file into the new repo as `PLAN.md`.** The executing agent will not have the `gaviero`
> Rust repo open. Everything needed to build the client is inline; citations to `gaviero` source are
> provenance only.

- **Plan date:** 2026-08-03 (originally 2026-08-01; resynced to Plan A V3 — see §0.1)
- **Version:** **V3**, numbered to match the Plan A revision it consumes. There was no Plan B V2 —
  the number tracks the protocol revision, not this document's edit count. Keep them equal: if Plan A
  reaches V4, this document becomes V4 or it is stale.
- **Executor:** **Opus 5** (`claude:opus`), working in a newly created, empty repo.
- **Companion:** Plan A (`remote-a-gaviero-sidecar-v3.md`) builds the WebSocket sidecar inside the
  gaviero TUI. **Plan A owns the protocol.** This plan consumes it and never invents wire messages.
- **Protocol:** `PROTOCOL_VERSION = { major: 1, minor: 0 }`, subprotocol `gaviero.v1`, path `/v1/ws`.
  (Plan A's *document* version is V3; the wire version is deliberately unrelated. Do not "fix" this.)
- **Deliverable:** an Android app (iOS later, same codebase) with native components that mirror and
  drive the gaviero agent chat panel — streaming messages, tool calls, permission approvals,
  `AskUserQuestion`, hunk-level write-gate review, conversation tabs, slash commands.

---

## 0. Executor contract (read first)

1. **The protocol is not yours.** `protocol.schema.json` and `PROTOCOL_VERSION` come from Plan A.
   Vendor the schema file into this repo and generate/validate the Dart codec against it. If you need
   a field that doesn't exist, that is a Plan A change request — do not invent it client-side.
2. **Pins in §2 are verified.** They were checked against the pub.dev registry on 2026-08-01. §2.1
   lists packages that look right and are wrong; do not accept them from a code sample.
3. **Verify by running on a real device**, not by `flutter analyze` passing.
4. Commit per work unit. Conventional commits. Do not push without being asked.
5. **This is not a terminal client.** An earlier design mirrored the TUI over SSH with `xterm.dart`
   and `dartssh2`. That was dropped. Neither package appears here.
6. **This document was written against an earlier protocol draft and resynced on 2026-08-03.** If you
   find any statement here that contradicts the vendored `protocol.schema.json`, the schema wins and
   it is a bug in this document — report it rather than coding around it.

---

## 0.1 What changed when Plan A reached V3

Plan A V1 (which this document originally consumed) was replaced by V2 and then V3. Everything below
changed on the wire. If you have already written code against the old shapes, these are your edits.

| # | Area | Was (V1) | Now (Plan A V3) | Affects |
|---|---|---|---|---|
| 1 | Highlight spans | `{ text, style }` | `{ start_byte, end_byte, class }` over **UTF-8 byte offsets**, semantic capture names | §3.1, B4 |
| 2 | Diff hunks | `{ index, old_lines, new_lines, status }` | Seven-field hunk; snapshots carry **summaries without text**; detail on demand | §3.1, §3.6, B7 |
| 3 | Slash commands | Free-form, inherits every desktop command | **Server allow-list** in `hello`; swarm/memory/`/run`/attachments denied | §3.2, B8 |
| 4 | `AskUserQuestion` answers | Client builds `updated_input` JSON | Client sends `answers: [[optionIndex]]`; the server rebuilds the tool input | §3.3, B6 |
| 5 | Metadata changes | A fresh `snapshot` every time | `conversation_state_changed`; snapshots on connect / gap / explicit request | §3.4, B3, B5 |
| 6 | Envelopes | Bare messages | `instance_id` + `command_id` on every client frame; one terminal result per command | §3.5, B2, B3 |
| 7 | Freshness | none | Per-entity tokens: `request_id`, `proposal_revision`, `conv_revision` | §3.5, B6, B7 |
| 8 | Auth | token on the handshake | `Authorization: Bearer` **header only**, plus subprotocol `gaviero.v1` | §2.4, B3 |
| 9 | Token rotation | `rotate_token` command | **Removed.** Desktop-only; you handle being disconnected | B3, B9 |
| 10 | Long transcripts | open question | `before_seq` pagination + `truncated` messages/hunks | §3.6, B4 |
| 11 | Plan A unit numbers | ntfy = A7, pairing = A5 | ntfy = **A8**, pairing = **A6**, live chat = A4, review = A5 | §1, §5 |

---

## 1. What you are building

A single-instance mobile client that connects over WebSocket to a gaviero TUI running on a PC,
reachable over Tailscale.

**Locked product decisions** (settled with the user — do not revisit):

| Decision | Choice |
|---|---|
| Session model | **Pure mirror.** The phone shows exactly the desktop's conversations; the PC is the source of truth. Creating a tab on the phone creates it on the desktop. |
| Transport | **Tailscale + WSS.** No public endpoint. The phone joins the tailnet. |
| Offline PC | If the TUI isn't running, show **"instance offline"**. There is no daemon mode. |
| Streaming | The server coalesces chunks on a ~50 ms timer; render them as live typing. |
| Pairing | **Scan a QR code** rendered in the TUI by its `/remote` command. |
| Attachments | **None in v1.** Text prompts only. |
| Alerts | **Local notifications** while connected/recently backgrounded. Always-on alerting is handled server-side by ntfy (Plan A, **A8**) — do not build a push backend. |
| Review authority | **Full hunk-level parity**: accept / reject / accept-all / reject-all / finalize. |
| Slash commands | **Server-allow-listed.** Build the command surface from `hello.allowed_slash_commands`; never hard-code a list (§3.2). |
| Confirm-gated commands | Read `hello.confirm_required` and raise a dialog before sending with `confirmed: true`. The initial set is `/autoapprove`, `/yolo`, `/reset`, `/clear`. |
| Token rotation | **Desktop-only.** There is no client command; rotation arrives as a disconnect (§3.7). |
| Concurrency | **Single client.** Connecting evicts any previous client — handle being evicted gracefully. |
| Scope | **Agent chat panel only.** No editor, file tree, terminal, or swarm view. |

---

## 2. Dependencies (verified on pub.dev, 2026-08-01)

Toolchain: **Flutter 3.44.8 / Dart 3.12.2** (stable, released 2026-07-23). Android **`minSdk 23`** —
required by `flutter_secure_storage` 10.x.

| Package | **Pin** | Latest | pub points | Role |
|---|---|---|---|---|
| `web_socket_channel` | `^3.0.3` | 3.0.3 (2025-04-17) | 150/160, 1638 likes | transport (Dart-team maintained) |
| `gpt_markdown` | `^1.1.8` | 1.1.8 (2026-07-16) | **160/160**, 309 likes | assistant-message rendering |
| `flutter_secure_storage` | `^10.3.1` | 10.3.1 (2026-05-27) | 150/160, 4468 likes | bearer token + host config |
| `mobile_scanner` | `^7.4.0` | 7.4.0 (2026-07-20) | **160/160**, 2285 likes | QR pairing scan |
| `flutter_local_notifications` | `^22.2.0` | 22.2.0 (2026-07-25) | 150/160, 7329 likes | agent-waiting alerts |

Let `flutter create` choose `flutter_lints` / `flutter_test`. Commit `pubspec.lock`.

### 2.1 Do not use these

| Package | Why |
|---|---|
| `flutter_markdown` | **DISCONTINUED** on pub.dev (last 0.7.7+1, 2025-05-06). This is the one you'll be handed by any older code sample. |
| `qr_code_scanner` | Last release **2022-08-15**, scores 60/160. Superseded by `mobile_scanner`. |
| `flutter_highlight` | Last release **2021**. See §3.1 — highlighting is done server-side. |
| `re_highlight` | 0.0.3, 24 likes. Not production-ready. |
| `xterm`, `dartssh2` | From the abandoned terminal-mirroring design. Not needed. |

### 2.2 State management

**Use `ChangeNotifier` + `ListenableBuilder`. Do not add Riverpod in v1.** A streaming chat with a
handful of screens is well within what the SDK handles, and every dependency here is one more thing
to keep current. `flutter_riverpod` 3.4.2 is healthy if the state graph later outgrows this — that is
a deliberate later decision, not a default.

### 2.3 Markdown gate

`gpt_markdown` is chosen because it targets LLM output specifically (its own description: "Ideal for
ChatGPT, Gemini"; deps are just `flutter` + `flutter_math_fork`; requires Dart `>=3.7.0`, satisfied).
**Gate in B4:** confirm its code-block builder gives enough control to paint server-supplied
highlight spans (§3.1). If it does not, switch to `flutter_markdown_plus` `^1.0.12` (also 160/160,
the direct continuation of the discontinued package). Decide this before building the rest of B4.

### 2.4 WebSocket client constraint (gate in B3)

Plan A V3 requires two things on the HTTP upgrade:

- `Authorization: Bearer <token>` — **the token is never in the URL, a query string, or the
  subprotocol.** The server rejects it anywhere else.
- WebSocket subprotocol `gaviero.v1`.

That means the transport must support **custom upgrade headers**. In `web_socket_channel` this is the
`dart:io`-backed `IOWebSocketChannel` (which exposes `headers` and `protocols`), not the generic
cross-platform constructor, which on the web has no header support at all.

**This is a gate, not a fact: verify it against the installed 3.0.3 API before building B3 on it.**
If `IOWebSocketChannel` cannot carry both a header map and a subprotocol list, fall back to
`dart:io`'s `WebSocket.connect(url, protocols:, headers:)` and wrap it yourself. Do **not** resolve a
header problem by putting the token in the URL — that is a Plan A change request, and the answer
will be no.

Android-only for v1, so the web transport's limitations are irrelevant; note them only so nobody
"simplifies" to the generic constructor later.

---

## 3. Design notes that shape the client

### 3.1 The server does the hard rendering work

Two things you would normally build in Dart are delivered ready-made over the wire.

**Syntax highlighting** arrives as byte-range spans, not styled text:

```text
code_blocks: [{
  start_byte, end_byte,        // the fenced block's range within `content`
  language?,
  truncated,                   // true => no spans; render plain
  spans: [{ start_byte, end_byte, class }]
}]
```

`class` is a **semantic tree-sitter capture name** — `keyword`, `string`, `function.method`, and so
on. The server deliberately does not send colors; you map class → your own theme, and any class you
do not recognize renders as plain text. That is a feature: the phone's dark theme is not the TUI's.

> **All offsets are UTF-8 byte offsets into `content`.** Dart strings are UTF-16, so
> `content.substring(start, end)` **is wrong** and will silently mis-highlight every message
> containing an accent, an emoji, or a box-drawing character. Convert once on receipt:
> `final bytes = utf8.encode(content);` then slice bytes and `utf8.decode` each span — or build a
> UTF-8-offset → UTF-16-index lookup table per message. Test with non-ASCII content, not just
> English code samples; this bug is invisible in ASCII.

**Diffs** arrive as structured hunks; you render rows, you do not diff:

```text
hunks: [{
  index,                       // stable position; send this back in review_action
  original_range, proposed_range,
  original_text, proposed_text,
  truncated,                   // true => text elided (over 64 KiB per side)
  hunk_type,                   // added | removed | modified
  description,                 // human summary from the server's structural diff
  status                       // pending | accepted | rejected
}]
```

A `truncated` hunk is still fully reviewable: you send `{ proposal_id, hunk_index, action }` and the
**server** assembles the file from its own copy. You never send file content. Render the elision
honestly ("… 2.1 MB not shown") rather than implying the user reviewed text they never saw.

This is why §2.1 bans the Dart highlighting packages — the good ones don't exist and you don't need
them.

### 3.2 Slash commands are server-allow-listed

**This reverses the original design.** Commands are *not* free-form pass-through, and the client does
*not* inherit every command the desktop gains. The server owns an explicit allow-list because the
desktop command set includes script execution (`/run`), swarm dispatch, memory deletion, and
attachment paths — all denied remotely.

- Build the entire command surface from **`hello.allowed_slash_commands`**. Hard-coding a list is a
  bug: it will show commands the server rejects and hide ones it gains.
- Gate on **`hello.confirm_required`** — currently `/autoapprove`, `/yolo`, `/reset`, `/clear`. Raise
  a real confirmation dialog, then send `slash { conv_id, line, confirmed: true }`.
- The initial allow-list is `/model`, `/thinking`, `/effort`, `/compact`, `/context`, `/inject`,
  `/no-inject`, `/reset`, `/clear`, `/rename`, `/namespace`, `/ns`, `/autoapprove`, `/yolo`,
  `/workspace`, `/ws`, `/lite`, `/minimal`, `/help`, `/skills`. Use it to *design* the chip row, not
  as runtime data.
- A denied or unknown command comes back as `command_error { code: "slash_not_allowed" }`. Show it as
  a normal, non-scary inline message — it is policy, not a failure.

Chips are prefilled or auto-sent text. `/model` and `/effort` take arguments — those chips
**prefill the composer** rather than send.

### 3.3 `AskUserQuestion` is a first-class screen, not a text prompt

`permission_request` may carry an `ask` object: a list of questions, each with `question`, `header`,
`multi_select`, and `options` as `(label, description)` pairs. Render these as native option cards —
radio semantics when `multi_select` is false, checkboxes when true. This is the interaction the app
most obviously beats a terminal at; give it real design attention.

**Answers are option indices, not a rebuilt tool-input document:**

```text
permission_decision { request_id, allow: true, answers: [[0], [1, 3]] }
```

One inner list per question, holding the selected option indices. The server validates the shape
(count matches, indices in range, exactly one selection when `multi_select` is false) and then
rebuilds the tool input itself, through the same code path the desktop uses.

The old design had the client construct `updated_input`. That was removed for security: it let a
client approve a *different* command than the one displayed. **Do not send `updated_input`; the
server will reject it.** For a plain (non-`ask`) tool approval, send `allow: true` with no `answers`
at all — the server echoes the original input unchanged.

`permission_request.input` is still sent to you, but it is **display-only**. Render it read-only so
the user can see exactly what they are approving.

### 3.4 State arrives two ways, and both must be idempotent

- **`snapshot`** — full authoritative state. Sent on connect, after a sequence gap, and in response
  to `request_snapshot`. Replace local state wholesale.
- **`conversation_state_changed { conversation, active_id }`** — a single `ConversationSummary` for
  title, model/effort/namespace, streaming state, auto-approve, context pressure, and active-tab
  changes. Upsert by `conv_id`.
- **`conversation_removed { conv_id, active_id }`** — drop it.

This replaces the original "every metadata change arrives as a fresh snapshot" design; snapshots are
now the exception, not the normal path. Build the state layer so applying either is cheap and
repeatable — you will apply the same snapshot twice, and you will receive a
`conversation_state_changed` for a conversation you already have.

Only `stream_chunk` is incremental within a message.

### 3.5 Envelopes, correlation, and freshness

Every **client** frame:

```text
{ version, instance_id, command_id, type, payload }
```

- `instance_id` comes from `hello`. Echo it on every frame. A different `instance_id` on an incoming
  frame means the TUI restarted — drop local state and resnapshot.
- `command_id` is yours, unique per command (a monotonic counter plus a session nonce is fine). The
  server deduplicates repeats within a recent-ID cache, so a retry after a flaky send is safe.

Every command gets **exactly one terminal response**: `command_result { command_id, status, result? }`
or `command_error { command_id, code, message }`. `status: accepted` is **terminal** — it means "validated
and started", and the outcome then arrives as normal lifecycle events keyed by the `turn_id` or
`proposal_id` in `result`. Do not wait for a second `completed`; it will never come.

Every **server** frame carries `seq` (monotonic per `instance_id`) and `revision`. A gap in `seq`
means you missed frames: send `request_snapshot`. `revision` is a global snapshot generation for
staleness display only — **never send it back as a precondition.**

Freshness is **per entity**, and you must track and send the right token:

| Command | Token to send | On mismatch |
|---|---|---|
| `permission_decision` | `request_id` | `stale_request` — the desktop answered first. Dismiss the sheet without an error. |
| `review_action` (any, incl. `finalize`) | `proposal_revision` | `stale_proposal` — re-read from the last `proposal_updated`, then let the user retry. |
| `rename_conversation`, `reset_conversation` | `conv_revision` | `stale_conversation` — refresh from the last `conversation_state_changed`. |
| `send_prompt`, `slash`, `switch_conversation`, `new_conversation`, `interrupt` | none | — |

**Never retry a stale command blindly.** Re-read the entity, show the user the current state, and let
them decide. The desktop and the phone are both live; losing a race is normal, not an error.

### 3.6 Transcripts are paginated and may be truncated

- `snapshot.active_conversation` carries at most the latest **100 messages** / 512 KiB, plus
  `oldest_seq` and `has_older_messages`.
- Older pages: `request_messages { conv_id, before_seq, limit }` → `message_page { conv_id, messages,
  oldest_seq, has_older_messages }`. `limit` is clamped to 1-200. The next request uses
  `before_seq = oldest_seq`. There is exactly one cursor concept — do not invent a second.
- `Message.seq` is a monotonic per-conversation id. It is **not** the envelope's `seq`. It survives
  `/compact` and `/reset`, so a stale cursor resolves to an empty range rather than to different
  content.
- A message over 128 KiB arrives with `truncated: true` and `full_bytes`. Render the head plus an
  honest "truncated" affordance.
- `snapshot.open_proposals` carries **summaries with no hunk text** (`proposal_id`,
  `proposal_revision`, `path`, `status`, `is_deletion`, `conflicts_with`, `hunk_count`,
  `added_lines`, `removed_lines`, and per-hunk `{ index, hunk_type, description, status }`). Fetch
  full text with `request_proposal { proposal_id }` → `proposal_detail`, or take it from the
  `proposal_created` / `proposal_updated` you are already receiving.

This closes the original open question about whether long conversations fit in a snapshot: they do
not, and the protocol now handles it. Design the message list for paging from the start.

### 3.7 Disconnects are routine — classify them

The server closes with application codes in the 4000-4999 range. Each needs a distinct UI:

| Code | Meaning | What the user should see |
|---|---|---|
| 4001 | `unauthorized` | "Pairing is no longer valid — scan the QR again." Clear the stored token. |
| 4002 | `unsupported_version` | "App and desktop versions don't match." Non-fatal, no retry loop. |
| 4003 / 4004 | `protocol_error` / `frame_too_large` | Client bug. Log it; reconnect once. |
| 4005 | `replaced` | "Connected on another device." Distinct message — **not** a network error. |
| 4006 | `token_rotated` | "Pairing was reset on the desktop." Clear the token; send to the pairing screen. |
| 4007 | `server_shutdown` | "Instance offline." Back off, poll gently. |
| 4008 | `slow_client` | Reconnect and resnapshot. Consider whether you are blocking the socket. |

Plus the routine one: the server pings every 20 s and closes after **60 s without pong or traffic**,
so backgrounding the app will drop the socket. **This is normal.** Reconnect on resume and take a
fresh snapshot; do not surface it as an error, and do not fight Android doze with a foreground
service — that is exactly why server-side ntfy exists (Plan A, A8).

---

## 4. Work units

Each unit is done when its **verification** passes on a real device, not when it compiles.

### B1 — Scaffold + pins
`flutter create`; add §2 pins; Android `minSdk 23`; `analysis_options.yaml`; camera permission for
`mobile_scanner`; notification permission for `flutter_local_notifications`.
*Verification:* `flutter analyze` clean; app launches on a physical Android device; record resolved
versions in the commit message.

### B2 — Protocol codec
Vendor `protocol.schema.json` from Plan A. Generate or hand-write Dart models for both envelopes
(§3.5), a `PROTOCOL_VERSION` major check, and a codec test fixture per message type — Plan A's A0
ships one JSON fixture for every client and server frame, so use those files rather than writing your
own.
*Verification:* round-trip test for every message against Plan A's fixtures; an unknown message type
is ignored with a warning, never a crash; an unknown **field** is ignored (minor-version
forward-compat); a protocol-major mismatch surfaces a clear, non-fatal UI error.

### B3 — Transport + connection lifecycle
Resolve the §2.4 header/subprotocol gate first. Then: bearer token from `flutter_secure_storage` sent
as an `Authorization` header, subprotocol `gaviero.v1`, `client_hello` as the **first frame after
upgrade**, `instance_id` + `command_id` on every outgoing frame, `seq`-gap detection →
`request_snapshot`, reconnect with exponential backoff, "instance offline" state, and the full close-code
table from §3.7.
*Verification:* kill Wi-Fi mid-turn and restore — the app resyncs with no duplicated or missing
messages; connecting from a second device shows a clear eviction notice (4005) on the first, distinct
from a network drop; background the app for two minutes and confirm resume reconnects silently;
confirm with a proxy or server log that the token appears **only** in the request header.

### B4 — Chat view
Message list with role-styled bubbles, `gpt_markdown` for assistant content, server-highlighted code
blocks (§2.3 gate first), incremental streaming append, typing indicator driven by
`streaming_status`, tool-call rows from `tool_call_started`, `truncated` message affordance, and
`before_seq` paging on scroll-back (§3.6).
*Verification:* a live agent turn renders incrementally and its content matches the desktop panel; a
code block containing **non-ASCII text and an emoji** highlights correctly (the UTF-8 offset trap in
§3.1); scrolling back through a 1000-message conversation pages without duplicates, gaps, or jumps.

### B5 — Conversation tabs
Tab strip or drawer over `snapshot.conversations`; create, switch, rename, reset. Apply
`conversation_state_changed` and `conversation_removed` as upserts (§3.4). Send `conv_revision` on
rename/reset and handle `stale_conversation` (§3.5). `/reset` and `/clear` are confirm-gated.
*Verification:* tabs created or renamed **on the desktop** appear on the phone, and vice versa,
without a full snapshot being sent; renaming the same conversation on both at once leaves both sides
agreeing, with the loser told why.

### B6 — Approvals
Permission sheet with allow/deny and read-only `input` display; `AskUserQuestion` as native option
cards honouring `multi_select`; answers returned as **`answers: [[optionIndex]]`** (§3.3 — not
`updated_input`); handle `permission_closed` arriving because the desktop answered first (dismiss
without error) and `stale_request` the same way.
*Verification:* a plain tool approval and a real multi-question `AskUserQuestion` both answered from
the phone, with the desktop showing the identical resulting tool input; a desktop-answered prompt
disappears cleanly from the phone; a multi-select question with two selections round-trips.

### B7 — Diff review
Native hunk list from `proposal_created` / `proposal_updated`, plus `request_proposal` for a proposal
first seen as a summary in a snapshot (§3.6). Accept, reject, accept-all, reject-all, finalize, using
`hunk_index` and sending `proposal_revision` (§3.5).
*Verification:* a real write-gate proposal reviewed and finalized from the phone; the file on disk
matches the accepted hunks exactly; a proposal with a `truncated` hunk still finalizes correctly and
the UI does not pretend the elided text was reviewed; accepting a hunk the desktop just changed
yields `stale_proposal` and a sane refresh, not a lost edit.

### B8 — Composer + chips
Multiline composer sending `send_prompt`; slash chips built from `hello.allowed_slash_commands`
(§3.2); argument-taking chips prefill; `hello.confirm_required` chips raise a dialog and send
`confirmed: true`; `slash_not_allowed` renders as a calm inline message; an interrupt button sending
`interrupt { conv_id }`.
*Verification:* `/model`, `/effort`, `/lite`, `/reset` all take effect, observed on the desktop;
`/autoapprove` and `/reset` cannot be sent without confirming; a command **not** in the allow-list is
absent from the chip row entirely; interrupt visibly cancels a running turn.

### B9 — Pairing
`mobile_scanner` reads the QR the TUI renders. Payload:

```json
{ "kind": "gaviero-remote", "url": "wss://host.tailnet.ts.net:PORT/v1/ws",
  "token": "SECRET", "workspace": "display-name", "protocol_major": 1 }
```

Validate `kind` and `protocol_major` before storing. Store host + token in
`flutter_secure_storage`; manual-entry fallback screen for when the camera or QR is unavailable.
There is **no in-app token rotation** — rotation happens on the desktop and reaches you as a 4006
close (§3.7), which should route back to this screen.
*Verification:* a fresh install pairs by scanning and connects without typing anything; a QR with a
different `protocol_major` is rejected with a clear message rather than a failed connection; rotating
the token on the desktop lands the app on the pairing screen with the stale token cleared.

### B10 — Status surfaces + notifications
Context-pressure bar, token usage, cost, streaming status. Local notification on
`permission_request` and on `streaming_ended`.
*Verification:* a notification fires when the agent blocks on a permission while the app is
backgrounded. **Expect Android doze to eventually kill the socket** — that is why server-side ntfy
exists (Plan A, **A8**); do not fight it with background services.

### B11 — Packaging
Android release APK, sideloaded — no Play Store. iOS deferred: the code is shared; the real cost is a
Mac and an Apple developer account for signing.

---

## 5. Sequencing

```text
B1 ──> B2 ──> B3 ──> B4 ──> B5 ──> B6 ──> B7 ──> B8 ──> B10 ──> B11
                       └──> B9 (any time after B3)
```

Plan A gates, using **V3** unit numbers:

- **B2 is blocked on Plan A / A0 + A1** — A0 freezes the schema and ships the frame fixtures, A1
  commits `protocol.schema.json`. B1 can start immediately.
- **B3-B6 need Plan A / A4** (outbound projection, prompt dispatch, snapshots) to test against
  anything real.
- **B7 needs Plan A / A5** (review DTOs and authority).
- **B9 needs Plan A / A6** (pairing, token, binding, certificate UX), but you can hard-code host +
  token to unblock B3-B8.
- Resolve the §2.4 transport gate before B3 and the §2.3 markdown gate before B4.

---

## 6. Open questions

| # | Question | Closed by |
|---|---|---|
| 1 | Does `gpt_markdown`'s code-block builder allow painting server-supplied byte-range spans? | B4 gate — fallback `flutter_markdown_plus` `^1.0.12` |
| 2 | Does `IOWebSocketChannel` 3.0.3 carry both custom headers and a subprotocol list? | B3 gate (§2.4) — fallback: wrap `dart:io` `WebSocket.connect` directly. Never move the token to the URL. |
| 3 | How aggressively does Android doze kill the socket in practice, and what reconnect cadence feels right? | B3/B10 on a real device |
| 4 | What is the cheapest correct way to map UTF-8 byte offsets onto Dart's UTF-16 strings for large messages — per-message lookup table or byte-slice-and-decode? | B4, measure on a 100 KiB message |

**Closed since the last revision:** "Is a long-conversation snapshot small enough to apply on every
metadata change?" — no, and it no longer needs to be. Metadata now arrives as
`conversation_state_changed` and transcripts are paginated (§3.4, §3.6).
