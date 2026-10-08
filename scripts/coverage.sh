#!/usr/bin/env bash
#
# Measures line coverage of HotspotGuardCore from a selftest run and enforces
# a threshold. No XCTest is needed: the selftest executable is built with
# LLVM coverage instrumentation (-profile-generate), run, and the resulting
# .profraw is reported with xcrun llvm-cov.
#
# Usage:
#   ./scripts/coverage.sh              # gate at the default threshold
#   COVERAGE_THRESHOLD=55 ./scripts/coverage.sh

set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Measured at 68.6% when the gate was introduced; kept deliberately below that
# to leave room for environments where the Keychain suites skip (headless CI).
THRESHOLD="${COVERAGE_THRESHOLD:-60}"

SCRATCH=".build-coverage"
PROFRAW="$SCRATCH/coverage.profraw"
PROFDATA="$SCRATCH/coverage.profdata"
REPORT="$SCRATCH/coverage.json"
BINARY="$SCRATCH/debug/hotspotguard-selftest"

rm -rf "$SCRATCH"

swift build --scratch-path "$SCRATCH" \
    -Xswiftc -profile-generate \
    -Xswiftc -profile-coverage-mapping

LLVM_PROFILE_FILE="$PROFRAW" "$BINARY"

xcrun llvm-profdata merge -sparse "$PROFRAW" -o "$PROFDATA"
xcrun llvm-cov export -format=text -summary-only "$BINARY" \
    -instr-profile="$PROFDATA" > "$REPORT"

python3 - "$REPORT" "$THRESHOLD" <<'PY'
import json
import sys

report_path, threshold = sys.argv[1], float(sys.argv[2])
with open(report_path) as handle:
    files = json.load(handle)["data"][0]["files"]

core = [f for f in files if "/Sources/HotspotGuardCore/" in f["filename"]]
covered = sum(f["summary"]["lines"]["covered"] for f in core)
total = sum(f["summary"]["lines"]["count"] for f in core)
percent = 100.0 * covered / total if total else 0.0

print(f"HotspotGuardCore line coverage: {percent:.1f}% "
      f"({covered}/{total} lines), threshold {threshold:.0f}%")
if percent < threshold:
    print("Coverage gate FAILED", file=sys.stderr)
    sys.exit(1)
PY
