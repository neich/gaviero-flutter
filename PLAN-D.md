# Plan D V1 — Gaviero Remote mobile app: instances and every tab (gaviero-flutter repo)

> **Copy this file into `gaviero-flutter/` as `PLAN-D.md`.** The executing agent will not have the
> `gaviero` Rust repo open. Everything needed is inline; citations to `gaviero` source are provenance
> only. Plan B V3 (`PLAN.md` in the same repo) remains the description of everything this plan does
> not change.

- **Plan date:** 2026-09-09
- **Executor:** Claude Code (`claude:opus`) or Codex (`codex:gpt-5.6-sol`), working in
  `gaviero-flutter/` (git repo, B1–B11 committed, 81 tests green as of 2026-08-05).
- **Companion:** Plan C (`remote-c-multi-instance-v1.md` in the gaviero repo) changes the sidecar and
  **owns the protocol**. This plan consumes wire **1.1** and never invents wire messages.
- **Protocol:** `PROTOCOL_VERSION = { major: 1, minor: 1 }`, subprotocol `gaviero.v1`, path `/v1/ws`
  — unchanged path and subprotocol; the minor bump is additive (§0.1).
- **Deliverable:** the app opens on an **instance picker** listing every running gaviero on every
  paired machine; pairing happens **once per machine**; once connected, a **tab strip** shows every
  conversation of that instance, each readable and drivable independently of the desktop's active tab.

---

## 0. Executor contract (read first)

1. **The protocol is not yours.** Re-vendor `protocol.schema.json` and the fixtures from Plan C's C0
   commit. Where this document and the vendored schema disagree, the schema wins — report it.
2. **No new packages.** The directory `GET` uses `dart:io` `HttpClient`; storage stays on
   `flutter_secure_storage`; everything else is already pinned in `pubspec.yaml`. Do not add `http`,
   `dio`, Riverpod, or a router package.
3. **Verify on a real device** where the unit says so; everything else must be machine-verifiable
   with `flutter test`. Record device-pending items in `plan_log.md` exactly as B3–B11 did.
4. Commit per work unit, conventional commits, do not push unasked.
5. **Backward compatibility is a requirement, not a nicety.** A 1.0 desktop (no `instances` /
   `latest_page` capability) must still pair, connect, and chat exactly as before.

---

## 0.1 What changed on the wire (1.0 → 1.1, all additive)

| # | Area | 1.0 | 1.1 | Affects |
|---|---|---|---|---|
| 1 | `hello.capabilities` | `[]` | contains `"latest_page"` and `"instances"` | feature detection, D1, D4 |
| 2 | `hello.machine` | absent | optional `{ host, directory_url? }` | learn the directory URL from any connection, D2 |
| 3 | `request_messages.before_seq` | required | **optional**; absent ⇒ the newest page (server treats it as `u64::MAX`) | open any tab cold, D4 |
| 4 | `GET /v1/instances` | — | new HTTPS resource, `Authorization: Bearer`, on every instance listener **and** on the machine directory port (default `49151`) | discovery, D2 |
| 5 | QR payload | 5 keys | optional `workspace_id`, `machine`, `directory_url` | pair once per machine, D3 |
| 6 | Token scope | one token per workspace | one token per **machine** by default (`remote.tokenScope`); a workspace may opt out and then has its own token | storage model, D2 |

`GET /v1/instances` response (fixture `protocol/fixtures/http/instances.json` after re-vendoring):

```json
{ "protocol_version": {"major":1,"minor":1}, "host": "neichtop.tail9b1d28.ts.net",
  "generated_at": "2026-09-09T12:00:00Z",
  "instances": [ { "instance_id": "9f1c…", "workspace": {"id":"0b7d245998c0e8c3","display_name":"gaviero"},
                   "url": "wss://neichtop.tail9b1d28.ts.net:52093/v1/ws", "port": 52093,
                   "tui_version": "0.1.0", "started_at": "2026-09-09T11:58:03Z",
                   "client_connected": false } ] }
```

`401` without a valid bearer, `429` when flooded, `404` for `/v1/ws` on the directory port. Entries
are only instances whose heartbeat is fresh (≤ 90 s), so "listed" means "running".

QR payload 1.1:

```json
{ "kind": "gaviero-remote", "url": "wss://host.tailnet.ts.net:PORT/v1/ws", "token": "SECRET",
  "workspace": "display-name", "protocol_major": 1,
  "workspace_id": "0b7d245998c0e8c3", "machine": "host.tailnet.ts.net",
  "directory_url": "https://host.tailnet.ts.net:49151/v1/instances" }
```

**Compatibility rules.** Feature-detect with `hello.capabilities`, never with `minor`. Without
`latest_page`, request the newest page with `before_seq: 9007199254740991` (2^53 − 1; a 1.0 server
parses it as a plain `u64` and returns the tail). Without `instances`, treat the instance as
directory-less: it is still connectable, it just never appears in another instance's list.

---

## 1. What you are building

Three user-visible changes on top of Plan B's app:

1. **Instance picker (home).** Machines and their running instances, live status, pull-to-refresh,
   tap to connect, long-press to forget. "Pair a machine" scans a QR.
2. **Pair once per machine.** The QR's token is the machine token; every instance on that machine
   uses it. Discovery fills in new workspaces without another scan.
3. **Every tab.** A scrollable tab strip lists all conversations in desktop order. The tab you are
   looking at is **local** (`viewedId`); the desktop's active tab is shown but not followed unless
   you turn on *Follow desktop*. Composer, permission card, interrupt, and paging all target the
   viewed tab. "Show on desktop" is an explicit long-press action.

**Locked decisions (do not revisit):**

| Decision | Choice |
|---|---|
| Session model | Still a pure mirror per instance. The PC is the source of truth for conversations; the phone adds only *which tab it is looking at*. |
| Connections | **One instance at a time.** Switching instances closes the previous socket. (Multi-socket monitoring is a later plan.) |
| Eviction | Unchanged — one client per instance, newest wins (4005). Different instances never evict each other. |
| Follow desktop | Off by default. On ⇒ `viewedId` tracks `active_id` (the Plan B behaviour). |
| Latest page | Authoritative: a newest-page response **replaces** the local transcript of that conversation; older pages merge. This is what makes a desktop `/reset` show correctly without a snapshot. |
| Unread | Counted per conversation on `message_complete` (assistant role) for tabs other than the viewed one; cleared when viewed. Not persisted. |
| Storage | One JSON document in secure storage (`instances_v2`); the three Plan B keys are migrated and then deleted. |
| Offline PC | Unchanged: the picker shows it offline; chat shows "instance offline". No daemon. |

---

## 2. Dependencies

Toolchain: **Flutter 3.44.8 / Dart 3.12.2** (installed). Pins unchanged from Plan B §2:
`web_socket_channel ^3.0.3`, `gpt_markdown ^1.1.8`, `flutter_secure_storage ^10.3.1`,
`mobile_scanner ^7.4.0`, `flutter_local_notifications ^22.2.0`. Plan B §2.1's do-not-use list still
applies.

The directory request is `dart:io` `HttpClient` with default certificate validation — Tailscale
certificates chain to Let's Encrypt, so **no pinning, no `badCertificateCallback`**. Wrap it behind a
`typedef DirectoryFetcher = Future<DirectoryResult> Function(Uri url, String bearerToken)` so tests
inject a fake, exactly as `WsConnector` does for the socket (`lib/src/transport/socket.dart`).

---

## 3. Design notes that shape the client

### 3.1 Machines, instances, and storage

```text
MachineRecord  { host, token, directoryUrl?, pairedAt }
InstanceRecord { machineHost, workspaceId?, displayName, url, lastSeen?, lastOnline }
InstanceKey    = (machineHost, workspaceId)        // workspaceId null until learned from hello
Store          { v: 2, machines: [...], instances: [...], lastInstance?: InstanceKey }
```

- `InstanceStore` (`lib/src/services/instance_store.dart`) replaces `PairingStore`
  (`lib/src/services/secure_store.dart`), reading/writing one JSON string under key `instances_v2`.
  On first load, if the legacy keys `pairing_url` / `pairing_token` / `pairing_workspace` exist,
  migrate them into one machine (host parsed from the URL, no `directoryUrl`) plus one instance, then
  delete the legacy keys. Migration is idempotent and tested.
- A machine's `directoryUrl` is learned from the QR, from `hello.machine.directory_url`, or from the
  manual form (host + optional directory port, default `49151` ⇒
  `https://<host>:49151/v1/instances`).
- `hello.workspace.id` always confirms or fills in `workspaceId`; `hello.workspace.display_name`
  refreshes the name.

### 3.2 Discovery

`refresh()` in `DirectoryClient` (`lib/src/services/directory_client.dart`), per machine, all in
parallel, 3 s timeout per request, never awaited by the UI thread beyond a spinner:

1. If `directoryUrl` is set, `GET` it. Success ⇒ upsert every listed instance (key by
   `workspace.id`), mark them online, record `client_connected` as *in use*.
2. Whether or not step 1 succeeded, `GET <origin of each known instance url>/v1/instances` for
   instances not yet marked online this round. A `404` means a 1.0 desktop: status *unknown* (still
   connectable). A connection error means offline.
3. `401` from any URL ⇒ the machine token is dead: mark the machine *needs pairing*; do **not** delete
   anything until the user confirms.

Known instances that did not appear this round keep their record and show *offline*. Nothing is
forgotten automatically.

### 3.3 Connection lifecycle per instance

`RemoteController.connect(InstanceRecord)` stops any current connection (`connection.stop()`, which
drops state), sets `current`, and starts the socket with that machine's token. `disconnect()` returns
to the picker. On `4001` / `4006` (`lib/src/transport/connection.dart:314-322`) the callback now clears
the **machine** token (every instance of that machine becomes *needs pairing*) and routes to the
pairing screen for that machine; other machines are untouched. Instance-change and seq-gap
handling are unchanged.

### 3.4 Viewed versus active

`AppState` (`lib/src/state/app_state.dart`) gains:

```text
viewedId: String?            // local
followDesktop: bool = false
ConversationData.transcriptLoaded: bool   // set only by a snapshot tail or a newest page
ConversationData.transcriptStale: bool    // set on every snapshot for non-active conversations
ConversationData.unread: int
```

Rules:

- `snapshot`: keep existing `ConversationData` objects for known ids (retain messages), update
  summaries, drop ids not present; the active conversation gets the tail (fresh, `transcriptLoaded`);
  every other known conversation is marked `transcriptStale`. This replaces the current
  "drop non-active transcripts" in `_applySnapshot` (`app_state.dart:192`).
- `viewedId` defaults to `active_id` when null or when its conversation disappears; with
  `followDesktop` it is overwritten by every `active_id` change (`_setActive`, `app_state.dart:236`).
- Viewing a conversation whose transcript is not loaded or is stale triggers **one** newest-page
  request (deduped like `requestOlderMessages`, `controller.dart:130`). The response replaces the
  transcript (§1 locked decision) and clears `transcriptStale`.
- `message_complete` for a conversation without a loaded transcript is kept (merged by `seq`) but
  does **not** set `transcriptLoaded`; the first view still fetches the newest page. This fixes the
  current `_insertMessage` behaviour that sets `oldestSeq` from a single live message
  (`app_state.dart:260-268`).
- `message_complete` with `role == assistant` on a conversation other than `viewedId` increments
  `unread`; viewing resets it.
- Permissions are already keyed by `conv_id` in `openPermissions`. The card shows the first open
  permission **for the viewed conversation**; a badge in the app bar counts open permissions on other
  tabs and taps through to the oldest one.

### 3.5 Paging any conversation

Newest page: `request_messages { conv_id, limit: 50 }` with `before_seq` omitted when
`hello.capabilities` contains `latest_page`, else `before_seq: 9007199254740991`. Older pages are
unchanged (`before_seq = oldestSeq`). Merge by `seq` for older pages; **replace** for newest pages.

### 3.6 Targeting

`sendPrompt`, `sendSlash`, `interrupt` (`controller.dart:81-101`) use `state.viewedId`, never
`activeId`. `switchConversation` stays the desktop-switch command and is reached only from the tab's
long-press menu ("Show on desktop") and from the drawer's overflow.

### 3.7 Notifications

`NotificationService` (`lib/src/services/notifications.dart`) messages gain the workspace display
name and the conversation title. The notification payload is `"<machineHost>|<workspaceId>|<convId>"`;
tapping it connects to that instance (if not current) and views that conversation.

---

## 4. Work units

Each unit is done when its verification passes; device-only checks go to `plan_log.md`.

### D1 — Codec 1.1

Re-vendor `protocol.schema.json` and all fixtures (now including `fixtures/http/instances.json`).
`Hello.machine` (nullable `MachineInfo`), `RequestMessages.beforeSeq` nullable and **omitted** when
null, `InstanceDirectory` / `InstanceInfo` models in `lib/src/protocol/directory.dart`,
`parsePairingPayload` reads the three optional keys. Bump `clientAppVersion` to `0.2.0`.
*Verification:* every 1.0 **and** 1.1 fixture round-trips; a `hello` without `machine` decodes; a
`request_messages` encoded with null `beforeSeq` has no `before_seq` key; the Dart protocol version
constant equals the vendored schema's; the `instances.json` fixture decodes and `client_connected`
survives.

### D2 — Instance store, migration, directory client

`InstanceStore` with the §3.1 document and legacy migration; `DirectoryClient.refresh()` per §3.2
with an injectable fetcher; a `FakeDirectoryFetcher` for tests.
*Verification:* migration from the three legacy keys yields one machine + one instance and deletes
the keys, and running it again changes nothing; refresh unions directory results with per-instance
probes; an instance absent from this round stays and is offline; `404` ⇒ unknown; `401` ⇒ machine
flagged, nothing deleted; a 3 s timeout does not delay other machines (fake_async).

### D3 — Instance picker, per-machine pairing, routing

`InstancePickerScreen` (home): sections per machine; rows show display name, `host:port`, a status
chip (online / in use / offline / unknown / needs pairing), and last seen; pull-to-refresh; tap ⇒
`controller.connect`; long-press ⇒ forget instance; machine overflow ⇒ forget machine (clears token).
FAB ⇒ scanner; the manual form now takes host, token, and optional port(s). `main.dart` routes:
picker is home; if `lastInstance` exists, push `ChatScreen` immediately (the connection banner covers
"offline"); the app bar of `ChatScreen` gains an *Instances* action that disconnects and pops.
`4001`/`4006` route to pairing **for that machine** with its name shown.
*Verification (widget tests):* a store with two machines and three instances renders three rows in
two sections with the right chips; tapping a row calls `connect` with that record; forget removes
only that row; pairing a QR whose `machine` matches an existing machine updates its token rather
than adding a duplicate. *Device:* fresh install ⇒ scan once ⇒ open a second workspace on the PC ⇒
pull-to-refresh shows it ⇒ connect to it without scanning.

### D4 — Every tab

`AppState` per §3.4; `RemoteController.view(convId)`, `requestNewestPage(convId)`, targeting per
§3.6; `ChatScreen` gets a scrollable `TabBar` under the app bar in server order, each tab showing the
title plus a streaming dot, a permission mark, and an unread count; a *Follow desktop* toggle and
"Show on desktop" long-press; the drawer keeps new / rename / reset. `Composer`, `PermissionCard`,
and `StatusStrip` read the viewed conversation.
*Verification (unit + widget):* a snapshot no longer discards a loaded non-active transcript; a
stale viewed transcript triggers exactly one newest-page request and the reply replaces it; with a
1.0 `hello` the request carries `before_seq: 9007199254740991`; `message_complete` on a non-viewed tab
increments unread and does not mark the transcript loaded; `sendPrompt` targets `viewedId` while
`active_id` differs; enabling follow-desktop snaps `viewedId` to `active_id` on the next
`conversation_state_changed`; the permission card shows only the viewed tab's request and the badge
counts the rest. *Device:* with two tabs streaming on the desktop, both tabs update live on the phone
while the desktop's active tab never changes.

### D5 — Notifications and surfaces per instance

§3.7 payloads and tap routing; `ConnectionBanner` names the instance; the picker's *in use* chip
explains "another device is connected — connecting will replace it".
*Verification:* notification body contains workspace and conversation title (unit); tapping a
notification while connected elsewhere switches instance and tab (device).

### D6 — Packaging and acceptance

Rebuild the release APK; update `README.md` (currently the `flutter create` stub) with pairing,
instances, and tabs; append `plan_log.md`.
*Device acceptance:* pair once; two PC workspaces listed; switch between them; on one, three tabs
with independent transcripts and prompts; desktop `/reset` on a non-viewed tab shows correctly when
viewed; `/remote rotate` on the PC lands the app on pairing for that machine with both instances
marked *needs pairing*.

---

## 5. Sequencing

```text
D1 ──> D2 ──> D3 ──> D5 ──> D6
 └───> D4 (after D1; touches app_state/controller/chat_screen/composer — coordinate with D3 on
           controller.dart and main.dart; land D3 first if the same agent does both)
```

Plan C gates: **C0 gates D1** (schema + fixtures). **C3 gates D2's and D3's device checks**
(directory endpoint). **C0 gates D4** (`latest_page`; the 2^53 − 1 fallback lets D4 be tested
against a 1.0 desktop meanwhile). **C4 gates D6** (`/remote` QR with the 1.1 keys).

---

## 6. Open questions

| # | Question | Closed by |
|---|---|---|
| 1 | Does `flutter_secure_storage` 10.x on the user's Android version accept a multi-kilobyte value for `instances_v2` without truncation? Expected yes (EncryptedSharedPreferences); test with 20 instances. | D2 |
| 2 | Should the app keep sockets to several instances open for notifications? Deferred; one at a time in this plan. Always-on alerting is A8: the TUI publishes to ntfy; the ntfy app delivers. | later plan |
| 3 | Tab strip versus drawer as the primary switcher on small screens — plan chooses the strip; revisit only after device use. | D4 device check |
