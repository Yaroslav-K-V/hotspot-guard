#!/usr/bin/env bash
#
# Builds HotspotGuard.app from the SwiftPM executable.
#
# SwiftPM produces a bare Mach-O binary, but a menu bar app needs a bundle:
# LSUIElement, the Location usage strings and the bundle identifier all live in
# Info.plist, and TCC/Keychain/SMAppService identify the app by that identifier
# plus its code signature. So: build, wrap, sign.
#
# Usage:
#   ./scripts/build-app.sh                 # release build, ad-hoc signed
#   CONFIGURATION=debug ./scripts/build-app.sh
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/build-app.sh
#   ./scripts/build-app.sh --install       # also copy to /Applications
#   ./scripts/build-app.sh --run           # also launch it

set -euo pipefail

APP_NAME="HotspotGuard"
CONFIGURATION="${CONFIGURATION:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT/.build/$APP_NAME.app"

INSTALL=0
RUN=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --run) RUN=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

echo "==> Building $APP_NAME ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product "$APP_NAME"
BIN_DIR="$(swift build -c "$CONFIGURATION" --product "$APP_NAME" --show-bin-path)"

echo "==> Assembling bundle"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
    echo "==> Signing with: $DEVELOPER_ID"
    # Hardened runtime is required for notarization; only meaningful with a
    # real Developer ID certificate.
    codesign --force --options runtime --timestamp \
             --sign "$DEVELOPER_ID" "$APP_BUNDLE"
else
    echo "==> Signing ad-hoc (no DEVELOPER_ID set)"
    # An ad-hoc signature is enough for the app to run and to use the Keychain,
    # but note two consequences:
    #   * SMAppService.register() ("Launch at Login") usually fails, because
    #     launchd validates the signature before installing a login item.
    #   * The signature changes on every rebuild, so macOS treats each build as
    #     a new app and re-asks for Location permission.
    codesign --force --sign - "$APP_BUNDLE"
fi

codesign --verify --verbose=2 "$APP_BUNDLE" 2>&1 | sed 's/^/    /'

echo "==> Built: $APP_BUNDLE"

if [[ $INSTALL -eq 1 ]]; then
    echo "==> Installing to /Applications"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
    APP_BUNDLE="/Applications/$APP_NAME.app"
    echo "==> Installed: $APP_BUNDLE"
fi

if [[ $RUN -eq 1 ]]; then
    echo "==> Launching"
    open "$APP_BUNDLE"
fi
