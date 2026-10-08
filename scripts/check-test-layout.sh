#!/usr/bin/env bash
#
# Enforces the selftest layout convention:
#
#   * one suite area per file, named after the type under test
#     (<Type>Tests.swift) with a run<Type>Tests() function inside;
#   * every runner must actually be called from main.swift — a suite file
#     that is never called is a silent test skip, the worst kind of green;
#   * the only non-suite files allowed are the shared infrastructure:
#     main.swift, TestRunner.swift, TestSupport.swift, Fakes.swift.
#
# Usage:
#   ./scripts/check-test-layout.sh

set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DIR="Sources/hotspotguard-selftest"
ALLOWED=" main.swift TestRunner.swift TestSupport.swift Fakes.swift "

status=0
for file in "$DIR"/*.swift; do
    name="$(basename "$file")"

    if [[ "$ALLOWED" == *" $name "* ]]; then
        continue
    fi

    if [[ "$name" != *Tests.swift ]]; then
        echo "$name: suite files must be named <Type>Tests.swift" >&2
        status=1
        continue
    fi

    base="${name%Tests.swift}"
    if ! grep -q "func run${base}Tests(" "$file"; then
        echo "$name: missing func run${base}Tests()" >&2
        status=1
    elif ! grep -q "run${base}Tests()" "$DIR/main.swift"; then
        echo "$name: main.swift never calls run${base}Tests() — the suite would not run" >&2
        status=1
    fi
done

if [[ $status -eq 0 ]]; then
    echo "Test layout OK."
fi
exit $status
