#!/usr/bin/env bash
#
# Syncs the label taxonomy declared in .github/labels.json into the GitHub
# repository. Idempotent: every label is created or updated (gh --force), so
# the file is the source of truth and re-runs converge. Deliberately does
# NOT delete labels missing from the file — removing is a human decision.
#
# The issue forms in .github/ISSUE_TEMPLATE/ apply `bug` and `enhancement`
# automatically; the rest are for triage.
#
# Usage:
#   ./scripts/sync-labels.sh           # upsert all labels into the repo
#   ./scripts/sync-labels.sh --check   # only verify the file parses (CI)

set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LABELS=".github/labels.json"

# Validate shape before touching the network.
python3 - "$LABELS" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    labels = json.load(handle)
assert labels, "labels.json is empty"
for label in labels:
    assert set(label) == {"name", "color", "description"}, label
    assert len(label["color"]) == 6 and all(c in "0123456789abcdef" for c in label["color"]), label
names = [label["name"] for label in labels]
assert len(names) == len(set(names)), f"duplicate label names: {names}"
print(f"{len(labels)} labels declared.")
PY

if [[ "${1:-}" == "--check" ]]; then
    exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "gh is not installed (brew install gh)." >&2
    exit 1
fi

python3 - "$LABELS" <<'PY' | while IFS=$'\t' read -r name color description; do
import json
import sys

for label in json.load(open(sys.argv[1])):
    print("\t".join([label["name"], label["color"], label["description"]]))
PY
    gh label create "$name" --color "$color" --description "$description" --force
    echo "  synced: $name"
done
