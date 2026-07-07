#!/bin/bash
# ── Ogma release helper ──────────────────────────────────────────
# Usage: bash release.sh <version>    (e.g. bash release.sh 2.0.0)
#
# Creates (or updates) a GitHub release from CHANGELOG.md.
# The CHANGELOG is the single source of truth for release notes.
#
# Steps:
#   1. Extracts the section for the given version from CHANGELOG.md
#   2. Appends a standard GitHub footer
#   3. Builds the installer pkg (build-pkg.sh) and a source zip
#   4. Creates a draft release (or updates if it already exists)
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

See the [README](https://github.com/Stover-Distributed-Systems-Incorporated/Ogma#readme) for full documentation."

# ── Build assets ─────────────────────────────────────────────────────
# Four assets: versioned + stable names for both the installer pkg and
# the source zip, so releases/latest/download/Ogma.pkg always works.
_TMPDIR=$(mktemp -d)
ASSET_NAME="ogma-${TAG}.zip"
ZIP="$_TMPDIR/$ASSET_NAME"
STABLE_ZIP="$_TMPDIR/ogma.zip"
git -C "$SCRIPT_DIR" archive --format=zip --prefix=ogma/ HEAD -o "$ZIP"
cp "$ZIP" "$STABLE_ZIP"

echo "Building installer pkg..."
bash "$SCRIPT_DIR/build-pkg.sh" "$VERSION"
PKG="$SCRIPT_DIR/dist/Ogma-$VERSION.pkg"
STABLE_PKG="$SCRIPT_DIR/dist/Ogma.pkg"

# ── Create or update release ─────────────────────────────────────────
if gh release view "$TAG" &>/dev/null; then
    echo "Updating existing release $TAG..."
    gh release edit "$TAG" --title "Ogma $TAG" --notes "$NOTES"
    # Remove old assets (both old and new naming conventions)
    for asset in ogma.zip "$ASSET_NAME" Ogma.pkg "Ogma-$VERSION.pkg"; do
        gh release delete-asset "$TAG" "$asset" --yes 2>/dev/null || true
    done
    gh release upload "$TAG" "$PKG" "$STABLE_PKG" "$ZIP" "$STABLE_ZIP"
else
    echo "Creating draft release $TAG..."
    gh release create "$TAG" "$PKG" "$STABLE_PKG" "$ZIP" "$STABLE_ZIP" \
        --title "Ogma $TAG" \
        --draft \
        --notes "$NOTES"
fi

rm -rf "$_TMPDIR"

echo ""
echo "Release $TAG ready."
echo "To publish: gh release edit $TAG --draft=false"
