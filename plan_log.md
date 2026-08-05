# Plan Execution Log

**Plan:** PLAN.md (Plan B V3 — Gaviero Remote mobile app)
**Started:** 2026-08-05
**Status:** Complete (B1–B11); on-device verification steps pending user
(no Android device/emulator was attached to the executing machine)

## Preconditions
- Plan A V3 executed: `gaviero/crates/gaviero-remote/` provides `protocol.schema.json`,
  `PROTOCOL.md`, and 33 frame fixtures. Wire version 1.0, subprotocol `gaviero.v1`.
- Toolchain matches pins exactly: Flutter 3.44.8 / Dart 3.12.2.
- Deviation: no physical Android device or emulator is attached to this machine, and the
  executor cannot attach one. All "verify on a real device" steps are recorded below as
  **pending user verification**; everything machine-verifiable (analyze, unit tests,
  release build) runs in their place.
- Note: `flutter doctor` reports Android cmdline-tools missing / license status unknown.
  Deferred to B11 (release build) — Gradle may or may not care.

## B2 — Protocol codec
- Vendored `protocol.schema.json` + all 33 fixtures into `protocol/`.
- Hand-written DTOs (no codegen dependency). 45 tests: per-fixture
  round-trips, unknown-type/-field tolerance, major-mismatch detection,
  Dart constants pinned to the vendored schema, UTF-8 offset slicing against
  the non-ASCII fixture.
- No deviations.

## B3 — Transport + connection lifecycle
- §2.4 gate resolved: installed `IOWebSocketChannel` 3.0.3 accepts both
  `headers:` and `protocols:` (forwarded to `dart:io WebSocket.connect`) —
  primary path works, no fallback wrapper needed.
- Full close-code table, seq-gap resnapshot, instance-change drop, backoff,
  command correlation. 14 lifecycle tests against a fake socket.
- **Pending user verification (needs device + running sidecar):** Wi-Fi
  kill/restore resync, 4005 eviction from a second device, 2-minute
  background resume, proxy/log check that the token is header-only.

## B4 — Chat view
- §2.3 gate resolved: `gpt_markdown` 1.1.8 has `codeBuilder` — kept. Chosen
  rendering goes further: completed messages are segmented at the
  server-declared block byte ranges; code renders natively from span runs,
  prose through GptMarkdown. Streaming buffer (no spans yet) renders whole.
- Deviation: a minimal composer shipped in B4 so the app is usable;
  B8 replaced it with the full chips/confirm surface. No outcome change.
- **Pending user verification:** live turn parity with the desktop panel,
  non-ASCII/emoji highlight on device, 1000-message scroll-back.

## B5 — Conversation tabs
- Drawer over the mirrored summaries; rename/reset carry `conv_revision`;
  stale_conversation surfaces calmly. Reset is confirm-gated.
- **Pending user verification:** cross-device tab create/rename mirroring,
  simultaneous rename race.

## B6 — Approvals
- Inline permission card (not a modal): `permission_closed` dismisses it by
  state change, so a desktop-answered prompt disappears cleanly by design.
- Widget tests pin the wire shape: `answers: [[1],[1,3]]`, plain allow has
  no `answers` key, single-select gating.
- **Pending user verification:** desktop shows the identical rebuilt tool
  input after a phone answer.

## B7 — Diff review
- Hunk cards with honest truncation notice; all five actions send
  `proposal_revision`; stale_proposal refreshes from the pushed
  `proposal_updated`. Summary-only proposals fetch detail on open.
- **Pending user verification:** finalize-from-phone disk parity, truncated
  hunk finalize, stale race against a desktop edit.

## B8 — Composer + chips
- Chips built solely from `hello.allowed_slash_commands`; argument chips
  prefill; confirm-gated chips dialog + `confirmed: true`;
  `slash_not_allowed` is a calm inline notice. Prompt size checked against
  `limits.max_prompt_bytes` in UTF-8 bytes. Six widget tests.
- **Pending user verification:** /model, /effort, /lite, /reset observed
  taking effect on the desktop; interrupt cancelling a live turn.

## B9 — Pairing
- `mobile_scanner` screen + manual wss/token fallback; payload validation
  rejects wrong `kind`, wrong `protocol_major` (clear message), non-wss
  URLs. 4006 → token cleared → pairing screen (wired since B3).
- **Pending user verification:** fresh-install scan-to-connect, desktop
  token rotation landing the app on pairing with the token cleared.

## B10 — Status surfaces + notifications
- Deviation: flutter_local_notifications 22.x moved `initialize`/`show` to
  named parameters; adapted (the plan's pin predates the signature change).
- Context-pressure bar, token usage, per-turn + session cost. Notifications
  fire only while backgrounded; no doze-fighting by design.
- **Pending user verification:** notification on a backgrounded permission
  request.

## B11 — Packaging
- Deviation: first release build failed — flutter_local_notifications 22.x
  requires core library desugaring, which the plan's B1 checklist did not
  mention. Fixed with isCoreLibraryDesugaringEnabled + desugar_jdk_libs
  2.1.5; rebuild succeeded.
- Deviation: the user changed minSdk from hard-coded 23 to
  flutter.minSdkVersion mid-run; Flutter 3.44.8's default is 24, which
  satisfies the plan's ≥23 floor, so it stands.
- `app-release.apk` (69.2 MB) built for sideloading. Note: signed with the
  debug key (flutter create default) — fine for sideloading; add a release
  keystore if that ever changes. Non-fatal Gradle warning about plugins and
  Built-in Kotlin. Android cmdline-tools/licenses turned out not to block
  the build. iOS deferred per plan.

## B1 — Scaffold + pins
- `flutter create -e --project-name gaviero_remote --org dev.gaviero --platforms android .`
- All five §2 pins resolved exactly: web_socket_channel 3.0.3, gpt_markdown 1.1.8,
  flutter_secure_storage 10.3.1, mobile_scanner 7.4.0, flutter_local_notifications 22.2.0.
- minSdk 23; CAMERA + POST_NOTIFICATIONS + INTERNET in the manifest.
- Deviation: agent tooling dirs (`.claude/`, `.codex/`, `.cursor/`, `.gaviero/`,
  `.mcp.json`) gitignored — local config, not app code.
- `flutter analyze` clean. **Pending user verification:** launch on a physical device.
