#!/usr/bin/env bash
set -euo pipefail

REPO="GregoryPletnev/dn"

need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "error: '$1' is required" >&2
        exit 1
    }
}

need curl
need dpkg

arch="$(dpkg --print-architecture)"
case "$arch" in
    amd64|arm64) ;;
    *)
        echo "error: unsupported Debian architecture: $arch" >&2
        exit 1
        ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

deb="$tmp/dn-datanavigator.deb"
url="https://github.com/$REPO/releases/latest/download/dn-datanavigator_latest_$arch.deb"

echo "Downloading DN - DataNavigator for Debian/Ubuntu ($arch)..."
curl -fL "$url" -o "$deb"

sudo_cmd=()
if [[ "$(id -u)" != "0" ]]; then
    need sudo
    sudo_cmd=(sudo)
fi

echo "Installing DN - DataNavigator..."
if ! "${sudo_cmd[@]}" dpkg -i "$deb"; then
    echo "Resolving package dependencies..."
    "${sudo_cmd[@]}" apt-get update
    "${sudo_cmd[@]}" apt-get install -f -y
fi

echo "Done. Run: dn"
