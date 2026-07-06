#!/usr/bin/env bash
# Builds a distributable DMG for Apple Silicon (arm64):
#   dist/DN-DataNavigator-<version>-arm64.dmg
#
# The DMG contains "DN - DataNavigator.app" (double-click opens the app in
# Terminal), with the Homebrew ncurses dylib bundled inside so the app runs
# on machines without Homebrew.
#
# Usage:
#   scripts/build-dmg.sh                 # ad-hoc signed
#   VERSION=1.2.0 scripts/build-dmg.sh
#   CODESIGN_IDENTITY="Developer ID Application: ..." scripts/build-dmg.sh
#   CODESIGN_IDENTITY="Developer ID Application: ..." \
#     NOTARY_PROFILE=<notarytool keychain profile> scripts/build-dmg.sh
#
# With a real identity the code gets hardened runtime + secure timestamp;
# with NOTARY_PROFILE the DMG is also notarized and stapled (requires a
# Developer ID identity and `xcrun notarytool store-credentials`).
set -euo pipefail

APP_NAME="DN - DataNavigator"
BIN_NAME="dn"
BUNDLE_ID="${BUNDLE_ID:-com.ftech-data.dn-datanavigator}"
VERSION="${VERSION:-1.1.0}"
IDENTITY="${CODESIGN_IDENTITY:--}" # "-" = ad-hoc signature

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
STAGING="$DIST/dmg-staging"
DMG="$DIST/DN-DataNavigator-$VERSION-arm64.dmg"

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "error: this script must run on an Apple Silicon Mac (uname -m = $(uname -m))" >&2
    exit 1
fi

echo "==> Building $BIN_NAME (clean release build)"
make -C "$ROOT" clean all

ARCH="$(lipo -archs "$ROOT/bin/$BIN_NAME")"
if [[ "$ARCH" != "arm64" ]]; then
    echo "error: bin/$BIN_NAME is '$ARCH', expected arm64" >&2
    exit 1
fi

echo "==> Assembling $APP_NAME.app"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"

cp "$ROOT/bin/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"

# Bundle the ncurses dylib the binary was linked against and point the
# binary at the bundled copy instead of the Homebrew path.
NCURSES_DYLIB="$(otool -L "$APP/Contents/MacOS/$BIN_NAME" | awk '/libncursesw/ {print $1}')"
if [[ -z "$NCURSES_DYLIB" ]]; then
    echo "error: could not find libncursesw reference in $BIN_NAME" >&2
    exit 1
fi
DYLIB_BASE="$(basename "$NCURSES_DYLIB")"
cp -L "$NCURSES_DYLIB" "$APP/Contents/Frameworks/$DYLIB_BASE"
chmod 644 "$APP/Contents/Frameworks/$DYLIB_BASE"
install_name_tool -id "@executable_path/../Frameworks/$DYLIB_BASE" \
    "$APP/Contents/Frameworks/$DYLIB_BASE"
install_name_tool -change "$NCURSES_DYLIB" \
    "@executable_path/../Frameworks/$DYLIB_BASE" \
    "$APP/Contents/MacOS/$BIN_NAME"

# Nothing in the bundle may still reference Homebrew paths.
for f in "$APP/Contents/MacOS/$BIN_NAME" "$APP/Contents/Frameworks/$DYLIB_BASE"; do
    if otool -L "$f" | tail -n +2 | grep -q '/opt/homebrew\|/usr/local'; then
        echo "error: $f still links against Homebrew libraries:" >&2
        otool -L "$f" >&2
        exit 1
    fi
done

cp "$ROOT/assets/dn.icns" "$APP/Contents/Resources/dn.icns"

# Bundle a terminfo subset: Homebrew's ncurses only searches Homebrew's
# terminfo path, which doesn't exist on machines without Homebrew. The
# binary falls back to this copy (+ /usr/share/terminfo) via TERMINFO_DIRS.
TERMINFO_SRC="$(brew --prefix ncurses)/share/terminfo"
for t in ansi vt100 vt220 linux xterm xterm-color xterm-256color xterm-new \
         screen screen-256color tmux tmux-256color rxvt rxvt-unicode \
         rxvt-unicode-256color alacritty xterm-kitty wezterm xterm-ghostty; do
    f="$(find "$TERMINFO_SRC" -maxdepth 2 -name "$t" -type f 2>/dev/null | head -1)"
    if [[ -n "$f" ]]; then
        sub="$(basename "$(dirname "$f")")"
        mkdir -p "$APP/Contents/Resources/terminfo/$sub"
        cp "$f" "$APP/Contents/Resources/terminfo/$sub/"
    fi
done
if [[ ! -d "$APP/Contents/Resources/terminfo" ]]; then
    echo "error: no terminfo entries copied from $TERMINFO_SRC" >&2
    exit 1
fi

# The bundle's main executable: opens the TUI binary in Terminal.
cat > "$APP/Contents/MacOS/$APP_NAME" <<'LAUNCHER'
#!/bin/bash
HERE="$(cd "$(dirname "$0")" && pwd)"
exec open -a Terminal "$HERE/dn"
LAUNCHER
chmod 755 "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>        <string>dn</string>
    <key>LSMinimumSystemVersion</key>  <string>11.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key>
    <string>Based on Dos Navigator by RIT Labs. Dos Navigator is Copyright © RIT Labs.</string>
</dict>
</plist>
PLIST

echo "==> Signing (identity: $IDENTITY)"
SIGN_FLAGS=()
if [[ "$IDENTITY" != "-" ]]; then
    # a real certificate: hardened runtime + secure timestamp (required
    # for notarization; harmless otherwise)
    SIGN_FLAGS=(--options runtime --timestamp)
fi
codesign --force "${SIGN_FLAGS[@]}" --sign "$IDENTITY" \
    "$APP/Contents/Frameworks/$DYLIB_BASE"
codesign --force "${SIGN_FLAGS[@]}" --sign "$IDENTITY" \
    "$APP/Contents/MacOS/$BIN_NAME"
codesign --force "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Creating DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp "$ROOT/README.md" "$STAGING/README.md"

rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

if [[ "$IDENTITY" != "-" ]]; then
    # the container needs its own signature for `spctl -t open` to accept it
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Notarizing (profile: $NOTARY_PROFILE)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" \
        --wait --timeout 20m
    xcrun stapler staple "$DMG"
fi

echo
echo "Done: $DMG"
if [[ "$IDENTITY" == "-" ]]; then
    echo "note: ad-hoc signature — on first launch users need right-click > Open"
    echo "      (for Gatekeeper-clean distribution set CODESIGN_IDENTITY and notarize)"
elif [[ -z "${NOTARY_PROFILE:-}" ]]; then
    echo "note: signed but not notarized — Gatekeeper still warns on other Macs"
    echo "      (set NOTARY_PROFILE to notarize; needs a Developer ID identity)"
fi
