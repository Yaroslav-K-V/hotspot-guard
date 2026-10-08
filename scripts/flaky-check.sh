#!/usr/bin/env bash
#
# Flakiness gate: runs the selftest several times and fails if the outcome
# ever changes — a different exit status or a different number of executed
# checks means a test depends on timing, ordering, network, or the machine's
# state. (This script exists because one did: a VPN made the "unroutable"
# RFC 5737 address answer TCP connections, which is why the probe's connector
# is now injected instead of relying on the network.)
#
# Usage:
#   ./scripts/flaky-check.sh        # 5 runs
#   RUNS=10 ./scripts/flaky-check.sh

set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RUNS="${RUNS:-5}"

swift build
BINARY=".build/debug/hotspotguard-selftest"

expected=""
for run in $(seq 1 "$RUNS"); do
    set +e
    output="$("$BINARY" 2>&1)"
    status=$?
    set -e

    count="$(printf '%s\n' "$output" | grep -oE '[0-9]+ checks passed' || true)"
    signature="$status:$count"

    if [[ -z "$expected" ]]; then
        expected="$signature"
    elif [[ "$signature" != "$expected" ]]; then
        echo "Run $run is flaky: got '$signature', earlier runs gave '$expected'." >&2
        exit 1
    fi
done

if [[ "${expected%%:*}" != "0" ]]; then
    echo "Not flaky — consistently failing. Fix the suite first:" >&2
    printf '%s\n' "$output" | tail -5 >&2
    exit 1
fi

echo "$RUNS identical runs ($expected). No flakiness detected."
