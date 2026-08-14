# HotspotGuard — design

**Date:** 2026-08-14
**Status:** implemented

macOS menu bar watchdog that detects loss of internet connectivity and
reassociates with a configured Wi-Fi hotspot.

## Constraints that shaped the design

Three environment facts were established before any code was written, and each
one changed a decision:

1. **No Xcode on the build machine** — only Command Line Tools. This rules out
   `.xcodeproj`, and it also rules out XCTest *and* swift-testing, since both
   ship inside Xcode. Build system is SwiftPM plus a bundling script; tests are
   a plain executable target.
2. **No Apple Developer ID** — ad-hoc signing only. `SMAppService.register()`
   is therefore expected to fail, so that failure is surfaced in the UI rather
   than swallowed, and the README documents the manual fallback.
3. **CoreWLAN requires Location on macOS 14+** — without it `ssid()` returns
   `nil` and `scanForNetworks` fails outright.

## Minimum deployment target: macOS 14.0

- `@Observable` is macOS 14+, and it is what keeps the core free of
  SwiftUI/Combine — the requirement that the logic be reusable from a CLI.
- CoreWLAN's Location gating landed in Sonoma; targeting 14 means one behaviour
  rather than `if #available` branches.
- `MenuBarExtra(.window)` has `TextField` focus bugs on macOS 13, and text
  fields live in the dropdown.

`SMAppService` (13+) is not the binding constraint.

## Structure

Two targets, with the boundary enforced by the compiler:

- `HotspotGuardCore` — no AppKit, no SwiftUI. `ConnectionManager`,
  `ConnectivityProbe`, `WiFiController`, `KeychainHelper`, `AppSettings`,
  `EventLog`, `LocationAuthorization`, `Notifications`, `Defaults`.
- `HotspotGuard` — `App.swift` (composition root + `AppModel`), `MenuBarView`,
  `HistoryView`, `LaunchAtLogin`, `StatusIcon`.
- `hotspotguard-selftest` — executable test suite.

A future CLI is a third target linking only Core. `ConnectionManager.tick()` is
public precisely so a one-shot check needs no loop.

## Key decisions

**`ConnectivityProbe` and `WiFiController` are protocols.** This is what makes
the reconnection logic testable — a fake reports "offline" on demand, and the
test asserts exactly one association attempt. Otherwise the only way to verify
anything is to physically drop Wi-Fi.

**TCP handshake rather than ICMP echo.** A real ping needs raw sockets and a
hand-built ICMP packet, and answers the wrong question: captive portals route
ICMP while blocking everything else, so ping reports "online" on exactly the
network where you are not. `1.1.1.1:443` and `8.8.8.8:53` are raced; first
success wins; `.waiting` (no route) is treated as immediate failure rather than
burning the timeout.

**CoreWLAN rather than `networksetup`.** `networksetup -setairportnetwork`
prompts for admin credentials on every invocation, which defeats an unattended
watchdog. CoreWLAN is quiet for networks macOS already knows.

**State machine:** `.idle` (grey) → `.connected` (green) → `.reconnecting`
(yellow) → `.disconnected` (red).

**Association is not success.** After associating, the manager waits for DHCP
and re-probes before claiming victory — otherwise joining a captive-portal
network counts as a fix.

**One notification per outage,** not per tick, guarded by
`hasNotifiedForCurrentOutage` and re-armed on recovery.

**Password in Keychain, everything else in UserDefaults.** UserDefaults is a
plist any user process can read. Keychain key is (bundle ID, SSID) so multiple
hotspots coexist. The password never reaches the event log.

## Post-implementation fix

Field testing (a real iPhone hotspot) surfaced a UX failure and a real bug:

- `ssidChanged()` fired on every keystroke in the SSID field and cleared
  `passwordDraft`, so typing the password first and then correcting the SSID
  silently discarded it. Fixed: the draft is no longer cleared there.
- Nothing distinguished "password typed" from "password saved". Added an
  explicit status line under the field, plus autosave when the menu closes.

## Verified

- Builds clean, no warnings.
- 54 self-test checks pass, including a real Keychain round-trip.
- `.app` bundle launches, lives in the menu bar, absent from Dock/app switcher.
- Real reconnect to an iPhone hotspot confirmed by the user.
