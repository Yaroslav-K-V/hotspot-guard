#!/usr/bin/env bash
#
# Formats the project with Apple's swift-format, using .swift-format at the
# repo root. The config encodes the established style: 4-space indent,
# 120-column lines, existing intentional line breaks preserved.
#
# Usage:
#   ./scripts/format.sh           # rewrite sources in place
#   ./scripts/format.sh --check   # lint only; exit non-zero if anything
#                                 # would be reformatted (for CI)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v swift-format >/dev/null 2>&1; then
    echo "swift-format is not installed. Install it with: brew install swift-format" >&2
    exit 1
fi

cd "$ROOT"

if [[ "${1:-}" == "--check" ]]; then
    # lint exits 0 even with findings, so fail the run when anything is found.
    OUTPUT="$(swift format lint --recursive --strict Package.swift Sources 2>&1)"
    if [[ -n "$OUTPUT" ]]; then
        echo "$OUTPUT"
        echo "Run ./scripts/format.sh to apply formatting." >&2
        exit 1
    fi
    echo "Formatting is clean."
else
    swift format --in-place --recursive Package.swift Sources
    echo "Formatted."
fi
