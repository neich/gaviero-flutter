# Gaviero Remote

Android (and iOS-capable) client for the gaviero TUI's remote sidecar. Pair
once per machine over Tailscale, pick which running instance to attach to,
and drive every conversation tab independently of the desktop's active tab.

Requires a gaviero TUI with remote enabled (default) on the same Tailscale
tailnet. Wire protocol **1.1** (`gaviero.v1`); a 1.0 desktop still pairs
and chats — it just has no instance directory and newest-page requests use
the `before_seq: 9007199254740991` fallback.

## Pairing

1. On the PC, in the gaviero TUI, run `/remote`.
2. In the app, scan the QR (FAB on the instance picker, or **Pair a
   machine**). Manual entry takes host, token, and optional instance /
   directory ports (directory defaults to `49151`).
3. The token is stored in platform secure storage. It is never logged or
   put in a URL.

A QR's token is a **machine** token: every workspace on that PC reuses it.
`/remote rotate` on the desktop invalidates it; the app returns to pairing
for that machine only.

## Instances

The home screen lists every paired machine and every instance last seen on
it.

| Chip | Meaning |
|---|---|
| online | Directory listed it (heartbeat ≤ 90 s) |
| in use | Another phone is connected — connecting replaces it |
| offline | Known, but not listed this refresh |
| unknown | `GET /v1/instances` returned 404 (1.0 desktop); still connectable |
| needs pairing | Token got `401` / close `4001` / `4006` |

Pull to refresh. Tap a row to connect (one instance at a time). Long-press
forgets that instance; machine overflow forgets the whole machine.

If a last-used instance is stored, the app opens chat immediately; the
connection banner covers "instance offline".

## Always-on alerts (ntfy)

Local notifications only fire while this app is connected (and die with
Android doze / the sidecar's idle cull). For a ping when **any** desktop
session finishes — even with the phone locked and this app not connected —
install the **ntfy** app, then in the TUI:

1. Set `notifications.ntfy.enabled: true` in user settings, restart gaviero.
2. Run `/ntfy` and scan the QR (or open the `ntfy://…` link) in ntfy.
3. Pair machines in Gaviero Remote as today.

Tapping an ntfy notification opens this app at
`gaviero-remote://open?host=&workspace=&conv=` when the instance is already
paired; otherwise the instance picker is shown. This app does **not**
subscribe to ntfy itself.

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

## Build

```bash
flutter test
flutter analyze
flutter build apk --release
```

Toolchain pin: Flutter 3.47.4 / Dart 3.13.3. Do not add `http`, `dio`,
Riverpod, or a router package. `app_links` (^7.2.1) is the one extra package
this plan allowed (ntfy click → open instance).
