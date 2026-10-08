#!/usr/bin/env bash
#
# Keeps AGENTS.md honest, in both directions:
#
#   * every ./scripts/*.sh it references must exist and be executable
#     (no phantom commands);
#   * every script on disk must be referenced in it (no undocumented tools);
#   * the config files and targets it names must exist;
#   * its required sections must be present.
#
# Usage:
#   ./scripts/check-agents-md.sh

set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DOC="AGENTS.md"
status=0

fail() {
    echo "AGENTS.md: $1" >&2
    status=1
}

[[ -s "$DOC" ]] || { echo "AGENTS.md is missing or empty" >&2; exit 1; }

# Scripts referenced but missing (or not executable).
referenced=$(grep -oE '\./scripts/[a-z0-9-]+\.(sh|py)' "$DOC" | sed 's|^\./||' | sort -u)
for script in $referenced; do
    if [[ ! -f "$script" ]]; then
        fail "references $script, which does not exist"
    elif [[ "$script" == *.sh && ! -x "$script" ]]; then
        fail "references $script, which is not executable"
    fi
done

# Scripts on disk but undocumented.
for script in scripts/*.sh; do
    if ! grep -qF "./$script" "$DOC"; then
        fail "$script exists but is not documented in $DOC"
    fi
done

# Named configs and the selftest target.
for config in .swiftlint.yml .swift-format .jscpd.json .periphery.yml .pre-commit-config.yaml; do
    [[ -f "$config" ]] || fail "mentions tooling whose config $config is missing"
done
grep -q "swift run hotspotguard-selftest" "$DOC" &&
    ! grep -q 'name: "hotspotguard-selftest"' Package.swift &&
    fail "documents 'swift run hotspotguard-selftest' but Package.swift has no such target"

# Required sections.
for section in "## Commands" "## Conventions" "## CI"; do
    grep -qF "$section" "$DOC" || fail "missing section: $section"
done

[[ $status -eq 0 ]] && echo "AGENTS.md is honest."
exit $status
