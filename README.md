# Gaviero Remote

Android (and iOS-capable) client for the gaviero TUI's remote sidecar. Pair
once per machine, pick which running instance to attach to, and drive every
conversation tab independently of the desktop's active tab.

Everything goes through **gaviero-relay**: one subdomain on port 443 of a VPS
you control. The relay is the
optional `crates/gaviero-relay` server in the gaviero repo; deployment is in its
README, and the full setup is in `docs/remote-relay.md`. Wire protocol **1.3**
(`gaviero.v1`).

```
phone ──TLS (SNI = <workspace-id>-<machine>.<relay host>)──▶ relay :443 ──▶ gaviero sidecar
gaviero ──wss://<relay host>/v1/host (dials out)──────────▶ relay
phone alert service ◀── /v1/phone/stream ── relay
```

## Desktop setup

Put the same two keys in `~/.gaviero/settings.json` on every machine:

```json
{ "remote": { "relay": {
    "host": "gaviero.example.com",
    "secret": "<the relay's --secret-file contents>"
} } }
```

Without `remote.relay.host` the sidecar does not start. With it, the sidecar
binds loopback only and dials out to the relay, so the machine needs no open
port and no DNS record. In the TUI, `/remote` shows
`Relay: wss://… — route … — registered`. Any other state (a 401, a timeout)
tells you why the phone can't connect.

## Security

- **End-to-end TLS:** TLS runs from the phone to the sidecar. The relay only
  sees the route name and ciphertext.
- **Pinned CA:** the pairing QR carries the machine's private CA (`tls_ca`).
  The app trusts **only** that CA for the machine (never the system roots)
  and keeps host-name checking on.
- **Routing:** with `relay_host` in the QR, every connection to that machine is
  dialled to the relay on 443. TLS starts with SNI = the URL host, which is the
  instance's route and is never looked up in DNS. Both pieces are in
  `lib/src/services/pinned_tls.dart`.

## Pairing

1. On the PC, in the gaviero TUI, run `/remote`.
2. In the app, scan the QR (FAB on the instance picker, or **Pair a
   machine**).
3. The token is stored in platform secure storage. It is never logged or
   put in a URL.

Pair by QR: it is the only way to pair a machine, because only the QR carries
the CA and the relay fields. The manual form (machine + token) only replaces
the token of a machine already paired by QR. A QR from a gaviero without
`remote.relay.host` is refused with that hint.

A QR's token is a **machine** token: every workspace on that PC reuses it.
`/remote rotate` on the desktop invalidates it; the app returns to pairing
for that machine only.

## Instances

The home screen lists every paired machine and every instance last seen on
it. One QR is enough per machine: every instance's route serves the machine's
instance list (`/v1/instances`) through the relay, so the other running
workspaces on that PC show up without scanning their QRs.

| Chip | Meaning |
|---|---|
| online | Listed by the machine (heartbeat ≤ 90 s) |
| in use | Another phone is connected — connecting replaces it |
| offline | Known, but not listed this refresh |
| unknown | `GET /v1/instances` returned 404 (1.0 desktop); still connectable |
| needs pairing | Token got `401` / close `4001` / `4006` |

Pull to refresh. Tap a row to connect (one instance at a time). Long-press
forgets that instance; machine overflow forgets the whole machine.

If a last-used instance is stored, the app opens chat immediately; the
connection banner covers "instance offline".

## Alerts

Pairing a relay machine starts the app's own alert service,
`RelayAlertService.kt`, and asks once for the battery-optimisation
exemption. The ntfy app is not needed. The service is a `specialUse`
foreground service with a permanent low-priority notification. It holds the
relay's `/v1/phone/stream` (NDJSON over HTTPS), one stream per relay.
- **Delivery:** it posts "<workspace> · Agent finished / needs you" while the
  phone is locked or the app is closed. The relay sends only
  `{machine, workspace, conv, kind}`; the app writes the text.
- **Resilience:** it reconnects on network/VPN changes and restarts after a
  reboot (`BootReceiver.kt`).
- **Tapping** an alert opens `gaviero-remote://open?host=&workspace=&conv=`,
  the conversation if the instance is paired, otherwise the instance picker.
- **No duplicates:** in-app local notifications are skipped for relay
  machines.
- **Plumbing:** native Kotlin with `HttpURLConnection` + `org.json`, so no new
  package. Dart only pushes the config through the `dev.gaviero/relay_alerts`
  MethodChannel (`lib/src/services/relay_alerts.dart`).

On the desktop, ntfy publishing still runs while
`notifications.ntfy.enabled` is on. Turn it off once relay alerts reach your
phone.

## Tabs

A scrollable strip under the app bar lists every conversation in desktop
order. The tab you are looking at is local (`viewedId`); the desktop's
active tab is marked in the drawer but not followed unless **Follow
desktop** is on.

Composer, interrupt, permissions, and paging target the viewed tab.
**Show on desktop** (tab long-press / drawer overflow) is the explicit
desktop-switch command.

## `@` file references

Typing `@` in the composer lists matching workspace files from the desktop
(same matcher as the desktop popup); tapping one inserts `@<path> `, and the
desktop reads that file into the prompt on send. Needs a gaviero build that
advertises the `file_completions` capability — older desktops simply show no
suggestions.

## Explorer

The folder icon in the app bar opens a read-only view of the desktop
workspace. Root folders match the desktop explorer and `@` completion; tap a
folder to expand it (directories first, `.git` hidden) and tap a file to open
it. Rust, TypeScript, and every other grammar-backed language are highlighted
from the desktop's tree-sitter captures; Markdown opens in **Preview** with a
**Raw** toggle. Files over 48 KiB show the first 48 KiB without highlighting,
and binary files are not shown. Nothing here writes — there is no save,
rename, or delete action. Needs a gaviero build that advertises the
`file_browser` capability; older desktops show an update hint and receive no
requests.

## Turn review

When a chat turn changes files on disk, the desktop holds that
conversation's next prompt until every changed file is decided. The chat
view shows a review card listing each file (A/M/D, overlap / binary /
"can only be accepted" flags) with four decisions, each applied at once:
**Accept** / **Reject** a file, **Accept all** / **Reject all** for the files
still undecided. Reject goes back to the pre-prompt version; decisions are
final. Send is disabled for prompts (slash lines still go) until the last
file is decided. Rejecting a file edited after the turn needs a confirmation
that only the desktop can give. Needs a gaviero build that advertises the
`turn_review` capability.

A review whose conversation has no tab here (closed on the desktop, or none
named) is never hidden: a badge in the app bar opens a list of them. Values
from a newer desktop (an unknown change kind, decision, or outcome) show as
`?` / "decided on desktop" rather than discarding the snapshot that carried
them. `/reset` and `/clear` say so when a review is pending — clearing the
chat does not decide it.

## Build

```bash
flutter test
flutter analyze
flutter build apk --release
```

Toolchain pin: Flutter 3.47.4 / Dart 3.13.3. Do not add `http`, `dio`,
Riverpod, or a router package. `app_links` (^7.2.1) is the one extra package
allowed; it routes alert taps (`gaviero-remote://open?…`) to the instance.
