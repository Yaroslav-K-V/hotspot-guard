#!/usr/bin/env bash
#
# Detects unused code with Periphery, using .periphery.yml at the repo root.
# Periphery builds the package with the index store and reports declarations
# nothing references. Exits non-zero when it finds any, which is what makes
# it usable as a CI gate.
#
# Public HotspotGuardCore declarations are retained on purpose (see
# .periphery.yml): they are the library surface a future CLI will link
# against.
#
# Usage:
#   ./scripts/dead-code.sh

set -euo pipefail

if ! command -v periphery >/dev/null 2>&1; then
    echo "Periphery is not installed. Install it with: brew install periphery" >&2
    exit 1
fi

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --strict: findings exit non-zero, so the script can gate CI.
periphery scan --strict "$@"
