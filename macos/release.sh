#!/bin/bash
# ── Ogma release helper ──────────────────────────────────────────
# Usage: bash release.sh <version>    (e.g. bash release.sh 2.0.0)
#
# Creates a new draft GitHub release from CHANGELOG.md.
# The CHANGELOG is the single source of truth for release notes.
#
# Steps:
#   1. Extracts the section for the given version from CHANGELOG.md
#   2. Appends a standard GitHub footer
#   3. Builds the installer pkg (build-pkg.sh) and a source zip
#   4. Creates a draft release at the exact committed build revision
#
# Publish manually: gh release edit v<version> --draft=false

set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: bash release.sh <version>" >&2
    echo "Example: bash release.sh 1.1.0" >&2
    exit 1
fi

TAG="v$VERSION"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGELOG="$SCRIPT_DIR/CHANGELOG.md"

if ! git -C "$SCRIPT_DIR" diff --quiet HEAD -- . ../LICENSE; then
    echo "Commit macOS and license changes before building a release." >&2
    exit 1
fi
if [ -n "$(git -C "$SCRIPT_DIR" ls-files --others --exclude-standard -- .)" ]; then
    echo "Commit or ignore untracked macOS files before building a release." >&2
    exit 1
fi
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "Release $TAG already exists; choose a new version." >&2
    exit 1
fi
REVISION=$(git -C "$SCRIPT_DIR" rev-parse HEAD)

if [ ! -f "$CHANGELOG" ]; then
    echo "Error: CHANGELOG.md not found at $CHANGELOG" >&2
    exit 1
fi

# ── Extract release notes from CHANGELOG.md ──────────────────────────
# Grab everything between "## v<version>" and the next "## v" heading.
NOTES=$(awk -v ver="## v$VERSION" '
    $0 == ver { found=1; next }
    found && /^## v/ { exit }
    found { print }
' "$CHANGELOG")

if [ -z "$NOTES" ]; then
    echo "Error: no section found for v$VERSION in CHANGELOG.md" >&2
    exit 1
fi

# Trim leading/trailing blank lines (awk for macOS portability)
NOTES=$(echo "$NOTES" | awk 'NF{p=1} p{lines[++n]=$0} END{while(n>0&&lines[n]=="")n--;for(i=1;i<=n;i++)print lines[i]}')

# Append GitHub-specific footer
NOTES="$NOTES

---

**Getting started:** download \`Ogma.pkg\` and double-click it. The package is
not notarized (no \$99/yr Apple Developer fee — the app is free), so the first
open needs a one-time approval: System Settings → Privacy & Security → **Open Anyway**.

Prefer building from source? Download \`ogma.zip\`, unzip, and double-click \`install.command\`.

See the [macOS README](https://github.com/Stover-Distributed-Systems-Incorporated/Ogma/tree/main/macos#readme) for full documentation."

# ── Build assets ─────────────────────────────────────────────────────
# Four assets: versioned + stable names for both the installer pkg and
# the source zip, so releases/latest/download/Ogma.pkg always works.
_TMPDIR=$(mktemp -d)
trap 'rm -rf "$_TMPDIR"' EXIT
ASSET_NAME="ogma-${TAG}.zip"
ZIP="$_TMPDIR/$ASSET_NAME"
STABLE_ZIP="$_TMPDIR/ogma.zip"
# Package only the macOS product now that the repository is multi-platform.
git -C "$SCRIPT_DIR" archive --format=zip --prefix=ogma/ HEAD:macos -o "$ZIP"
# Include the repository license in the standalone macOS source download.
mkdir -p "$_TMPDIR/source/ogma"
git -C "$SCRIPT_DIR/.." archive --format=tar HEAD LICENSE | tar -xf - -C "$_TMPDIR/source/ogma"
(cd "$_TMPDIR/source" && zip -q "$ZIP" ogma/LICENSE)
cp "$ZIP" "$STABLE_ZIP"

echo "Building installer pkg..."
bash "$SCRIPT_DIR/build-pkg.sh" "$VERSION"
PKG="$SCRIPT_DIR/dist/Ogma-$VERSION.pkg"
STABLE_PKG="$SCRIPT_DIR/dist/Ogma.pkg"

# ── Create the new release ───────────────────────────────────────────
printf '%s\n' "$NOTES" > "$_TMPDIR/release-notes.md"
echo "Creating draft release $TAG at $REVISION..."
gh release create "$TAG" "$PKG" "$STABLE_PKG" "$ZIP" "$STABLE_ZIP" \
    --target "$REVISION" \
    --title "Ogma $TAG" \
    --draft \
    --notes-file "$_TMPDIR/release-notes.md"

echo ""
echo "Release $TAG ready."
echo "To publish: gh release edit $TAG --draft=false"
