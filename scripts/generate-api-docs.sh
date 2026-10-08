#!/usr/bin/env bash
#
# Generates the HotspotGuardCore API reference from the compiler's symbol
# graph (no docc needed — CLT-only machines have none) and writes
# docs/api/HotspotGuardCore.md.
#
# Usage:
#   ./scripts/generate-api-docs.sh           # regenerate the committed file
#   ./scripts/generate-api-docs.sh --check   # fail if the committed file is stale (CI)

set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MODULE="HotspotGuardCore"
TARGET="docs/api/$MODULE.md"

# A dedicated scratch path, like coverage.sh: building in the main .build
# would let incremental builds skip re-emitting the symbol graph, and the
# renderer would find no input. A clean build here is what makes --check
# trustworthy.
SCRATCH=".build-api-docs"
GRAPH="$SCRATCH/symbolgraph/$MODULE.symbols.json"

rm -rf "$SCRATCH"
swift build --scratch-path "$SCRATCH" --target "$MODULE" \
    -Xswiftc -emit-symbol-graph \
    -Xswiftc -emit-symbol-graph-dir \
    -Xswiftc "$SCRATCH/symbolgraph"

if [[ ! -f "$GRAPH" ]]; then
    echo "No symbol graph emitted at $GRAPH" >&2
    exit 1
fi

render() {
    python3 scripts/symbolgraph2md.py "$GRAPH" "$MODULE"
}

if [[ "${1:-}" == "--check" ]]; then
    if ! diff -u "$TARGET" <(render) > /dev/null; then
        echo "$TARGET is stale. Run ./scripts/generate-api-docs.sh and commit the result." >&2
        exit 1
    fi
    echo "API docs are up to date."
else
    mkdir -p docs/api
    render > "$TARGET"
    echo "Wrote $TARGET"
fi
