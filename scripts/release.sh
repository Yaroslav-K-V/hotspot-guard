#!/usr/bin/env bash
#
# Cuts a release: verifies the tree is in a releasable state, runs the full
# local quality gate, bumps the bundle version, commits, tags, and pushes.
# The pushed tag is what triggers .github/workflows/release.yml, which builds
# the app and creates the GitHub Release with generated notes.
#
# Usage:
#   ./scripts/release.sh 1.1.0
#
# This PUSHES to origin (main plus the new tag) — that is the release.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: $0 <major.minor.patch>  (e.g. $0 1.1.0)" >&2
    exit 2
fi
TAG="v$VERSION"

echo "==> Checking repository state"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" ]]; then
    echo "Releases are cut from main, not '$BRANCH'." >&2
    exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Working tree is not clean. Commit or stash first." >&2
    exit 1
fi
git fetch origin --quiet
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
    echo "main is not in sync with origin/main. Pull/push first." >&2
    exit 1
fi
if git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null ||
    git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; then
    echo "Tag $TAG already exists." >&2
    exit 1
fi

echo "==> Running the quality gate (the same checks CI runs)"
./scripts/format.sh --check
./scripts/lint.sh
./scripts/duplicates.sh
./scripts/check-test-layout.sh
./scripts/dead-code.sh
swift build
swift run hotspotguard-selftest

echo "==> Bumping version to $VERSION"
# Build number: commit count. Monotonic without bookkeeping, and it maps every
# released build back to a point in history.
BUILD_NUMBER=$(( $(git rev-list --count HEAD) + 1 ))
plutil -replace CFBundleShortVersionString -string "$VERSION" Resources/Info.plist
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" Resources/Info.plist

git add Resources/Info.plist
git commit --quiet -m "Release $TAG"
git tag -a "$TAG" -m "HotspotGuard $VERSION"

echo "==> Pushing main and $TAG (this triggers the release workflow)"
git push origin main
git push origin "$TAG"

echo "==> Released $TAG. Watch the workflow: gh run watch"
