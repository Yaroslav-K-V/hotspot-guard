# AGENTS.md — HotspotGuard

Guidance for AI agents (and humans) working in this repository.

## What this is

A macOS menu-bar app (Swift, SwiftUI) that keeps a Mac tethered to a phone
hotspot: it watches connectivity, re-associates Wi-Fi, detects captive
portals, and tries configured networks in priority order. SwiftPM-only, no
external dependencies, builds with Command Line Tools (no Xcode required).

## Layout

- `Sources/HotspotGuard/` — the app target (AppKit/SwiftUI, composition root
  in `App.swift`).
- `Sources/HotspotGuardCore/` — all logic, UI-free and testable.
- `Sources/hotspotguard-selftest/` — the test suite: a plain executable with
  its own tiny runner (`TestRunner`), because XCTest needs Xcode.
- `scripts/` — every check runnable by humans, agents, and CI alike.
- `docs/` — design and protocol notes. `README.md` (Ukrainian) — user docs.

## Setup

`brew bundle` (reads `Brewfile`) installs the whole toolchain on a Mac.
`.devcontainer/` gives non-macOS contributors the cross-platform subset
(swift-format, jscpd, pre-commit) — the app itself cannot build off macOS.

## Commands

```bash
swift build                            # builds all targets (do this — the
                                       # selftest alone never compiles the app)
swift run hotspotguard-selftest        # 330+ checks; exits non-zero on failure
./scripts/format.sh [--check]          # swift-format, .swift-format config
./scripts/lint.sh                      # SwiftLint, .swiftlint.yml
./scripts/duplicates.sh                # jscpd copy-paste gate, .jscpd.json
./scripts/dead-code.sh                 # Periphery unused-code scan
./scripts/check-test-layout.sh         # test file naming + suite registration
./scripts/coverage.sh                  # line coverage gate for Core (60%)
./scripts/flaky-check.sh               # 5 runs must be identical
./scripts/build-app.sh                 # build + wrap + sign .app bundle
./scripts/release.sh 1.2.3             # gated version bump, tag, push
./scripts/generate-api-docs.sh [--check]  # regenerate docs/api/, or verify freshness
./scripts/make-demo-gif.sh [shots] [out]  # assemble README demo GIF from --shot-dir frames
./scripts/check-agents-md.sh           # this file must not lie
./scripts/clean-keychain.sh            # wipe dev Keychain entries (ad-hoc signing)
./scripts/sync-labels.sh [--check]     # sync .github/labels.json to repo labels
pre-commit run --all-files             # the fast subset, runs on commit
```

Before considering work done, run at minimum: `swift build`,
`swift run hotspotguard-selftest`, `format.sh --check`, `lint.sh`,
`dead-code.sh`. Piping a script into `tail`/`grep` without `pipefail` masks
its exit code — don't.

## Environment gotchas

- **CLT-only machines**: SwiftLint needs `XCODE_DEFAULT_TOOLCHAIN_OVERRIDE`
  pointed at the CLT; `lint.sh` sets it automatically when `xcode-select -p`
  is the CLT path. Full-Xcode machines (CI) are untouched.
- **Keychain**: its suites skip gracefully when unavailable (headless CI), so
  check counts can legitimately differ between environments.
- **Network in tests**: never depend on "this address is unroutable" — a VPN
  or transparent proxy will answer anything. `TCPConnectivityProbe` takes an
  injectable `connector:` for exactly this reason.
- **SceneBuilder**: a conditional `Window` scene fails to compile on the
  current toolchain; scenes stay declared, flags gate their entry points.

## Conventions (enforced, not aspirational)

- Formatting: swift-format, 4 spaces, 120 columns. SwiftLint runs as a second,
  mandatory gate — when the two disagree (multi-line conditions + opening
  braces), restructure the code so both accept it.
- Naming: `lowerCamelCase` members, `UpperCamelCase` types; SwiftLint's
  `identifier_name`/`type_name` are errors.
- Tests: one suite area per file, `Sources/hotspotguard-selftest/<Type>Tests.swift`
  with `run<Type>Tests()`, registered in `main.swift`;
  `check-test-layout.sh` fails if a file is misnamed or never called.
- Duplication: jscpd threshold is 1%; share helpers instead of copying.
- Dead code: Periphery runs `--strict`; delete, don't comment out.
- TODOs are allowed but tracked (SwiftLint `todo` warning) — don't leave them
  where they will rot unnoticed.
- Feature flags (`FeatureFlags.swift`) are ops-level switches, not user
  settings: launch arg > `defaults` key `flags.<name>` > built-in default.

## Git

- Imperative, sentence-style commit messages (see `git log`).
- Nothing ships by hand: `./scripts/release.sh <x.y.z>` is the release path;
  it runs the full gate before tagging. Tags trigger the release workflow.

## CI

`.github/workflows/ci.yml` (two parallel macOS jobs running these same
scripts), `release.yml` (tag-driven GitHub Release with generated notes),
`nightly.yml` (rolling prerelease when main moved).
