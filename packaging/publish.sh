#!/bin/bash
# Publishes a release end to end: builds and notarises the disk image, uploads
# it to the GitHub release, and updates the checksum in both copies of the cask
# (this repo's reference copy and the tap that `brew install` actually reads).
#
#   ./packaging/publish.sh
#
# Needs a stored notarisation credential:
#   xcrun notarytool store-credentials cadviewer --apple-id <id> --team-id RGKP6D55BR
set -euo pipefail

IDENTITY="${IDENTITY:-Developer ID Application: Andrii Velhov (RGKP6D55BR)}"
PROFILE="${PROFILE:-cadviewer}"
VERSION="${VERSION:-$(sed -n 's/^ *version "\(.*\)"/\1/p' packaging/homebrew/cadviewer.rb)}"
TAG="v${VERSION}"
DMG="packaging/CADViewer-${VERSION}.dmg"
TAP_REPO="andriivelhov/homebrew-tap"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "No notarisation credential named '$PROFILE'. Store one first:" >&2
  echo "  xcrun notarytool store-credentials $PROFILE \\" >&2
  echo "      --apple-id <your-apple-id> --team-id RGKP6D55BR" >&2
  exit 1
fi

echo "==> building and notarising $VERSION"
VERSION="$VERSION" ./packaging/build_release.sh "$IDENTITY" "$PROFILE"

echo "==> publishing $TAG"
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG" --clobber
else
  gh release create "$TAG" "$DMG" --title "CAD Viewer $VERSION" --generate-notes
fi

# Verify against what GitHub actually serves, not the local file: the cask's
# checksum gates every install, and a mismatch fails for everyone but the author.
echo "==> checksumming the published asset"
TMP=$(mktemp -d)
curl -sL -o "$TMP/dl.dmg" \
  "https://github.com/andriivelhov/cad-viewer/releases/download/$TAG/CADViewer-$VERSION.dmg"
SHA=$(shasum -a 256 "$TMP/dl.dmg" | cut -d' ' -f1)
LOCAL=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
rm -rf "$TMP"
[ "$SHA" = "$LOCAL" ] || { echo "published asset differs from the local one" >&2; exit 1; }
echo "    $SHA"

update_cask() {
  /usr/bin/sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" \
                     -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$1"
}

echo "==> updating the cask in this repo"
update_cask packaging/homebrew/cadviewer.rb

echo "==> updating the tap that brew reads"
TAPDIR=$(mktemp -d)
gh repo clone "$TAP_REPO" "$TAPDIR/tap" -- -q
update_cask "$TAPDIR/tap/Casks/cadviewer.rb"
git -C "$TAPDIR/tap" add -A
if git -C "$TAPDIR/tap" diff --cached --quiet; then
  echo "    tap already current"
else
  git -C "$TAPDIR/tap" commit -q -m "cadviewer $VERSION"
  git -C "$TAPDIR/tap" push -q origin HEAD
  echo "    tap updated"
fi
rm -rf "$TAPDIR"

echo
echo "Published $VERSION. Install with:"
echo "  brew update && brew upgrade --cask cadviewer"
