#!/usr/bin/env bash
#
# Lints the project with SwiftLint, using .swiftlint.yml at the repo root.
#
# SwiftLint loads SourceKit from the active developer directory, and on a
# Command Line Tools-only machine (no Xcode, which is exactly the setup this
# project targets) the default lookup fails. Pointing SourceKitten at the
# CLT toolchain explicitly fixes that.
#
# Usage:
#   ./scripts/lint.sh            # lint; exit 0 unless error-level violations
#   ./scripts/lint.sh --strict   # warnings also fail the run

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v swiftlint >/dev/null 2>&1; then
    echo "SwiftLint is not installed. Install it with: brew install swiftlint" >&2
    exit 1
fi

# Only override when no Xcode is selected: on a CLT-only machine the default
# SourceKit lookup fails, while on CI (full Xcode) the default is correct.
if [[ "$(xcode-select -p)" == "/Library/Developer/CommandLineTools" ]]; then
    export XCODE_DEFAULT_TOOLCHAIN_OVERRIDE="${XCODE_DEFAULT_TOOLCHAIN_OVERRIDE:-/Library/Developer/CommandLineTools}"
fi

cd "$ROOT"
swiftlint lint "$@"
