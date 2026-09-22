#!/usr/bin/env bash

# Cleans up ad-hoc Keychain entries created by HotspotGuard during local development.
# Run this script to avoid permission prompt loops.

SERVICE="com.yaroslavkv.hotspotguard"

echo "Cleaning up Keychain items for service: $SERVICE"

# Find and delete items matching the service
security delete-generic-password -s "$SERVICE" >/dev/null 2>&1

if [ $? -eq 0 ]; then
    echo "Successfully deleted $SERVICE Keychain items."
else
    # Security command returns error if no items were found, which is fine
    echo "No Keychain items found for $SERVICE."
fi

# Try the bundle identifier just in case it's different
BUNDLE_SERVICE=$(xcodebuild -showBuildSettings | grep PRODUCT_BUNDLE_IDENTIFIER | awk '{print $3}')
if [ -n "$BUNDLE_SERVICE" ] && [ "$BUNDLE_SERVICE" != "$SERVICE" ]; then
    echo "Cleaning up Keychain items for bundle service: $BUNDLE_SERVICE"
    security delete-generic-password -s "$BUNDLE_SERVICE" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "Successfully deleted $BUNDLE_SERVICE Keychain items."
    fi
fi
