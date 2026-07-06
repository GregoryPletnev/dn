#!/usr/bin/env bash
# Builds a Debian package: dist/dn-datanavigator_<version>_<arch>.deb
#
# Run on Debian/Ubuntu (needs fpc, libncursesw5-dev, dpkg-deb):
#   make deb
#   VERSION=1.2.0 scripts/build-deb.sh
set -euo pipefail

PKG="dn-datanavigator"
VERSION="${VERSION:-1.1.0}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "error: .deb packages are built on Linux (this is $(uname -s));" >&2
    echo "       use 'make dmg' for the macOS package" >&2
    exit 1
fi
command -v dpkg-deb >/dev/null || { echo "error: dpkg-deb not found" >&2; exit 1; }

MAINTAINER="${MAINTAINER:-$(git -C "$ROOT" config user.name 2>/dev/null || echo DN) \
<$(git -C "$ROOT" config user.email 2>/dev/null || echo nobody@localhost)>}"
ARCH="$(dpkg --print-architecture)"
STAGING="$DIST/deb/$PKG"
DEB="$DIST/${PKG}_${VERSION}_${ARCH}.deb"

echo "==> Building dn (clean release build)"
make -C "$ROOT" clean all

echo "==> Staging package tree"
rm -rf "$DIST/deb"
mkdir -p "$STAGING/DEBIAN" \
         "$STAGING/usr/bin" \
         "$STAGING/usr/share/applications" \
         "$STAGING/usr/share/doc/$PKG" \
         "$STAGING/usr/share/icons/hicolor/1024x1024/apps"

install -m 755 "$ROOT/bin/dn" "$STAGING/usr/bin/dn"
install -m 644 "$ROOT/README.md" "$STAGING/usr/share/doc/$PKG/README.md"
install -m 644 "$ROOT/assets/dn-icon-1024.png" \
        "$STAGING/usr/share/icons/hicolor/1024x1024/apps/$PKG.png"

cat > "$STAGING/usr/share/doc/$PKG/copyright" <<EOF
DN - DataNavigator
Written from scratch in Free Pascal for Unix terminals.

Based on the ideas and code analysis of the original Dos Navigator by
RIT Labs. Dos Navigator is Copyright (C) RIT Labs; all credit for the
original design belongs to them.
EOF

cat > "$STAGING/usr/share/applications/$PKG.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=DN - DataNavigator
Comment=Dos Navigator look-and-feel file manager for the terminal
TryExec=dn
Exec=dn
Icon=$PKG
Terminal=true
Categories=System;FileTools;FileManager;
Keywords=file;manager;panel;navigator;
EOF

INSTALLED_SIZE=$(du -sk "$STAGING/usr" | cut -f1)
cat > "$STAGING/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Architecture: $ARCH
Maintainer: $MAINTAINER
Installed-Size: $INSTALLED_SIZE
Section: utils
Priority: optional
Depends: libc6, libncursesw6, libtinfo6
Recommends: libarchive-tools, openssh-client
Homepage: https://t.me/My_CTO_Notes
Description: DN - DataNavigator, a Dos Navigator-style file manager
 Two-panel, keyboard-driven terminal file manager recreating the look
 and feel of the classic Dos Navigator with Free Pascal and ncurses.
 Archives and disk images open as directories, remote panels work over
 SFTP, and the built-in MicroEd editor and viewer open in windows.
EOF

echo "==> Building $DEB"
mkdir -p "$DIST"
dpkg-deb --build --root-owner-group "$STAGING" "$DEB"
rm -rf "$DIST/deb"

echo
echo "Done: $DEB"
