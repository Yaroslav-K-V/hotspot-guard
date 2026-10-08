#!/usr/bin/env bash
#
# Detects copy-paste duplication with jscpd, using .jscpd.json at the repo
# root. Exits non-zero when duplicated lines exceed the configured threshold
# (1% — the codebase currently sits at 0% and should stay there), which makes
# it usable both as a pre-commit hook and a CI gate.
#
# Usage:
#   ./scripts/duplicates.sh

set -euo pipefail

if ! command -v npx >/dev/null 2>&1; then
    echo "npx is not installed. Install Node.js first (e.g. brew install node)." >&2
    exit 1
fi

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Pinned version so every machine and CI run the same detector.
npx --yes jscpd@4.0.5
