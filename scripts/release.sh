#!/usr/bin/env bash
# release.sh — one-shot release orchestration.
#
#   1. Build release binaries (macOS now; linux/windows are stubs — see below).
#   2. Push the release commit + tag to GitLab (origin, source of truth).
#   3. Create the GitLab release (notes only, NO binary assets).
#   4. Wait until the push-mirror has propagated the tag to GitHub.
#   5. Create the matching GitHub release and upload the binaries there.
#
# The split is deliberate: GitLab is private and holds no binaries; the public
# GitHub mirror is where users download from (GitHub Release assets). See
# PUBLISHING.md for the whole GitLab -> GitHub -> Pages -> Cloudflare setup.
#
# Usage:
#   scripts/release.sh <version> [notes-file]
#   scripts/release.sh 1.2.0
#   scripts/release.sh 1.2.0 RELEASE_NOTES.md
#
# Env knobs:
#   RELEASE_YES=1     skip the confirmation prompt (for automation)
#   MACOS_ADHOC=1     ad-hoc DMG (build-dmg.sh) instead of signed+notarized
#   GITLAB_HOST / GITLAB_REPO       override; default derived from origin remote
#   GITHUB_REPO=<owner>/<repo>      GitHub owner/repo (default GregoryPletnev/dn)
#   MIRROR_TIMEOUT=600              seconds to wait for the mirror (default 600)
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"

# Derive the private GitLab host + project path from the origin remote instead
# of hardcoding them (this script lives in the public mirror).
ORIGIN_URL="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
GITLAB_HOST="${GITLAB_HOST:-$(sed -E 's#^https?://([^/]+)/.*#\1#' <<<"$ORIGIN_URL")}"
GITLAB_REPO="${GITLAB_REPO:-$(sed -E 's#^https?://[^/]+/(.+)\.git$#\1#' <<<"$ORIGIN_URL")}"
export GITLAB_HOST                       # so glab targets the right instance

GITHUB_REPO="${GITHUB_REPO:-GregoryPletnev/dn}"
MIRROR_TIMEOUT="${MIRROR_TIMEOUT:-600}"

VERSION="${1:-}"
NOTES_FILE="${2:-}"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ -n "$VERSION" ]] || die "usage: scripts/release.sh <version> [notes-file]"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be X.Y.Z (got '$VERSION')"
TAG="v$VERSION"

# ---------------------------------------------------------------------------
# Preflight — fail fast before we build or publish anything
# ---------------------------------------------------------------------------
say "Preflight"
command -v glab >/dev/null || die "glab not found (brew install glab)"
command -v gh   >/dev/null || die "gh not found (brew install gh)"
glab auth status --hostname "$GITLAB_HOST" >/dev/null 2>&1 \
    || die "glab not authenticated for $GITLAB_HOST (glab auth login --hostname $GITLAB_HOST)"
glab repo view "$GITLAB_REPO" >/dev/null 2>&1 \
    || die "GitLab repo '$GITLAB_REPO' unreachable via glab API — check token scope and project membership"
gh   auth status >/dev/null 2>&1 || die "gh not authenticated (gh auth login)"
gh repo view "$GITHUB_REPO" >/dev/null 2>&1 \
    || die "GitHub repo '$GITHUB_REPO' unreachable — create it / check gh auth (see PUBLISHING.md)"

[[ -z "$(git -C "$ROOT" status --porcelain)" ]] \
    || die "working tree is dirty — commit or stash before releasing"

BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD)"

if git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    die "tag $TAG already exists locally — bump the version or delete the tag"
fi
if git -C "$ROOT" ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; then
    die "tag $TAG already exists on GitLab origin"
fi

if [[ -n "$NOTES_FILE" ]]; then
    [[ -f "$NOTES_FILE" ]] || die "notes file not found: $NOTES_FILE"
fi

say "Release $TAG  (branch $BRANCH @ $COMMIT)"
say "  GitLab: $GITLAB_REPO    GitHub: $GITHUB_REPO"
if [[ "${RELEASE_YES:-0}" != "1" ]]; then
    read -r -p "Proceed with build + publish? [y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || die "aborted"
fi

# ---------------------------------------------------------------------------
# 1. Build binaries
# ---------------------------------------------------------------------------
ASSETS=()

build_macos() {
    if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
        warn "not on Apple Silicon macOS — skipping macOS DMG"
        return
    fi
    say "Building macOS DMG (arm64)"
    if [[ "${MACOS_ADHOC:-0}" == "1" ]]; then
        VERSION="$VERSION" "$ROOT/scripts/build-dmg.sh"
    else
        VERSION="$VERSION" "$ROOT/scripts/release-macos.sh"   # signed + notarized
    fi
    local dmg="$DIST/DN-DataNavigator-$VERSION-arm64.dmg"
    [[ -f "$dmg" ]] || die "expected DMG not produced: $dmg"
    ASSETS+=("$dmg")
}

build_linux() {
    # SKIPPED for now. To enable: build the .deb on Linux (native or via
    # colima/Docker or a GitLab CI runner — see PUBLISHING.md) so that
    #   dist/dn-datanavigator_${VERSION}_arm64.deb  (and/or amd64)
    # exists, then append it to ASSETS. Example once available:
    #   local deb="$DIST/dn-datanavigator_${VERSION}_amd64.deb"
    #   [[ -f "$deb" ]] && ASSETS+=("$deb")
    warn "linux .deb build skipped (no Linux toolchain here) — will add later"
}

build_windows() {
    # No Windows target: the whole UI layer (dnscreen and friends) is built on
    # ncurses, a Unix library. A Windows build needs the screen layer ported to
    # pdcurses / the Windows console first — that is code work, not a build
    # flag. Tracked as a porting task (see ROADMAP.md), not done in this script.
    warn "windows build skipped — no Windows target yet (ncurses UI, needs a port)"
}

build_macos
build_linux
build_windows

[[ ${#ASSETS[@]} -gt 0 ]] || die "no binaries were built — nothing to release"
say "Built ${#ASSETS[@]} artifact(s):"
for a in "${ASSETS[@]}"; do printf '     %s (%s)\n' "$(basename "$a")" "$(du -h "$a" | cut -f1)"; done

# ---------------------------------------------------------------------------
# Release notes: use the given file, else auto-generate from the git log
# ---------------------------------------------------------------------------
NOTES_TMP="$(mktemp)"
trap 'rm -f "$NOTES_TMP"' EXIT
if [[ -n "$NOTES_FILE" ]]; then
    cp "$NOTES_FILE" "$NOTES_TMP"
else
    PREV_TAG="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
    {
        echo "## DN - DataNavigator $VERSION"
        echo
        if [[ -n "$PREV_TAG" ]]; then
            echo "Changes since $PREV_TAG:"
            echo
            git -C "$ROOT" log --pretty='- %s' "$PREV_TAG..HEAD"
        else
            echo "Initial tagged release."
        fi
    } > "$NOTES_TMP"
fi

# ---------------------------------------------------------------------------
# 2. Push commit + tag to GitLab (origin) — this is what triggers the mirror
# ---------------------------------------------------------------------------
say "Tagging $TAG and pushing to GitLab origin"
git -C "$ROOT" tag -a "$TAG" -m "Release $VERSION"
git -C "$ROOT" push origin "$BRANCH"
git -C "$ROOT" push origin "$TAG"

# ---------------------------------------------------------------------------
# 3. GitLab release — notes only, no binary assets
# ---------------------------------------------------------------------------
say "Creating GitLab release (no binaries)"
glab release create "$TAG" \
    --repo "$GITLAB_REPO" \
    --name "DN - DataNavigator $VERSION" \
    --notes-file "$NOTES_TMP"

# ---------------------------------------------------------------------------
# 4. Wait for the push-mirror to carry the tag to GitHub
# ---------------------------------------------------------------------------
say "Waiting for GitHub mirror to receive $TAG (timeout ${MIRROR_TIMEOUT}s)"
deadline=$(( $(date +%s) + MIRROR_TIMEOUT ))
until gh api "repos/$GITHUB_REPO/git/refs/tags/$TAG" >/dev/null 2>&1; do
    if (( $(date +%s) >= deadline )); then
        die "tag $TAG not on GitHub after ${MIRROR_TIMEOUT}s.
       Nudge the mirror: GitLab -> $GITLAB_REPO -> Settings -> Repository ->
       Mirroring repositories -> Update now, then re-run only the GitHub step:
         gh release create $TAG ${ASSETS[*]} --repo $GITHUB_REPO \\
           --title \"DN - DataNavigator $VERSION\" --notes-file <notes> --verify-tag"
    fi
    printf '     ...not yet, retrying in 15s\n'
    sleep 15
done
say "Mirror is up to date"

# ---------------------------------------------------------------------------
# 5. GitHub release — copy of the notes + binaries uploaded here
# ---------------------------------------------------------------------------
say "Creating GitHub release and uploading binaries"
gh release create "$TAG" "${ASSETS[@]}" \
    --repo "$GITHUB_REPO" \
    --title "DN - DataNavigator $VERSION" \
    --notes-file "$NOTES_TMP" \
    --verify-tag

echo
say "Done."
printf '     GitLab:  https://%s/%s/-/releases/%s\n' "$GITLAB_HOST" "$GITLAB_REPO" "$TAG"
printf '     GitHub:  https://github.com/%s/releases/tag/%s\n' "$GITHUB_REPO" "$TAG"
printf '     Assets:  %s\n' "$(printf '%s ' "${ASSETS[@]##*/}")"
