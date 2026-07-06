#!/usr/bin/env bash
# One-shot macOS release: signed with the FTech Developer ID, notarized,
# stapled, Gatekeeper-verified.
#
#   scripts/release-macos.sh                # version from build-dmg.sh default
#   VERSION=1.2.0 scripts/release-macos.sh
#
# One-time setup on a new machine:
#   1. Xcode > Settings > Accounts > Manage Certificates:
#      create "Developer ID Application" (FTech account)
#   2. xcrun notarytool store-credentials ftech \
#        --apple-id <apple-id> --team-id QBYJ6J2XYL --password <app-specific>
set -euo pipefail

IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: FTECH, MCHJ (QBYJ6J2XYL)}"
PROFILE="${NOTARY_PROFILE:-ftech}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
    echo "error: signing identity not found in the keychain:" >&2
    echo "       $IDENTITY" >&2
    echo "       (Xcode > Settings > Accounts > Manage Certificates)" >&2
    exit 1
fi
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "error: notarytool profile '$PROFILE' is missing or invalid; run:" >&2
    echo "       xcrun notarytool store-credentials $PROFILE \\" >&2
    echo "         --apple-id <apple-id> --team-id QBYJ6J2XYL --password <app-specific>" >&2
    exit 1
fi

CODESIGN_IDENTITY="$IDENTITY" NOTARY_PROFILE="$PROFILE" "$ROOT/scripts/build-dmg.sh"

DMG="$(ls -t "$ROOT"/dist/DN-DataNavigator-*.dmg | head -1)"
echo "==> Gatekeeper check"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"
echo
echo "Release ready: $DMG"
