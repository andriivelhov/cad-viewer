#!/bin/bash
# Builds, signs and packages CAD Viewer into a distributable disk image.
#
#   ./packaging/build_release.sh ["Signing Identity"]
#
# With no identity the bundle is ad-hoc signed: the app runs, but macOS will
# not load the QuickLook extension, and other machines get a Gatekeeper
# warning. Shipping to other people needs a "Developer ID Application"
# certificate plus notarisation.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${1:--}"
NOTARIZE_PROFILE="${2:-}"   # keychain profile name; enables notarisation
# Notarisation requires the hardened runtime and a secure timestamp. Neither
# is wanted for an ad-hoc local build, which cannot be notarised anyway.
case "$IDENTITY" in
  "Developer ID"*) SIGNFLAGS=(--options runtime --timestamp) ;;
  *)               SIGNFLAGS=(--timestamp=none) ;;
esac
VERSION=$(grep -o 'MACOSX_BUNDLE_SHORT_VERSION_STRING "[^"]*"' CMakeLists.txt \
          | head -1 | sed 's/.*"\(.*\)"/\1/')
VERSION="${VERSION:-1.0}"
STAGE=$(mktemp -d)
DMG="packaging/CADViewer-${VERSION}.dmg"

# A previously signed and stapled bundle is protected by macOS, and CMake
# cannot rewrite its Info.plist ("Operation not permitted"). Clear it first.
rm -rf build/CADViewer.app

echo "==> building"
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
      -DCODESIGN_IDENTITY="$IDENTITY" >/dev/null
cmake --build build -j"$(sysctl -n hw.ncpu)" >/dev/null

echo "==> bundling dependencies"
python3 tools/bundle_dylibs.py build/CADViewer.app

echo "==> re-signing (rewriting Mach-O invalidates the signature)"
# Inside-out: dylibs, then the extension, then the app.
codesign --force --sign "$IDENTITY" "${SIGNFLAGS[@]}" \
         build/CADViewer.app/Contents/Frameworks/*.dylib 2>/dev/null || true
# The extension must be sandboxed or macOS will not register it.
for ext in CADThumbnail CADPreview; do
  codesign --force --sign "$IDENTITY" "${SIGNFLAGS[@]}" \
           --entitlements "app/quicklook/${ext}.entitlements" \
           "build/CADViewer.app/Contents/PlugIns/${ext}.appex"
done
codesign --force --sign "$IDENTITY" "${SIGNFLAGS[@]}" build/CADViewer.app

echo "==> verifying signature"
codesign --verify --strict --verbose=1 build/CADViewer.app 2>&1 | tail -2 || true

echo "==> staging"
ditto build/CADViewer.app "$STAGE/CAD Viewer.app"

# Notarise the app itself, not just the disk image. A ticket stapled to the DMG
# covers only the DMG, and a cask copies the app out of it -- so without this
# the installed app carries no ticket and has to reach Apple on first launch.
# Staple the staged copy rather than build/CADViewer.app: macOS protects a
# stapled bundle, and a protected bundle in the build tree stops CMake from
# rewriting Info.plist on the next configure.
if [ -n "$NOTARIZE_PROFILE" ]; then
  echo "==> notarising the app (this takes a few minutes)"
  ditto -c -k --keepParent "$STAGE/CAD Viewer.app" "$STAGE/CADViewer.zip"
  xcrun notarytool submit "$STAGE/CADViewer.zip" \
        --keychain-profile "$NOTARIZE_PROFILE" --wait
  rm -f "$STAGE/CADViewer.zip"
  xcrun stapler staple "$STAGE/CAD Viewer.app"
fi
ln -s /Applications "$STAGE/Applications"

echo "==> creating $DMG"
rm -f "$DMG"
hdiutil create -volname "CAD Viewer" -srcfolder "$STAGE" \
        -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

codesign --force --sign "$IDENTITY" "${SIGNFLAGS[@]}" "$DMG" 2>/dev/null || true

echo
echo "$DMG  ($(du -h "$DMG" | cut -f1))"
codesign -dv build/CADViewer.app 2>&1 | grep -E "Identifier=|TeamIdentifier=" || true

if [ -n "$NOTARIZE_PROFILE" ]; then
  echo "==> notarising the disk image (this takes a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARIZE_PROFILE" --wait
  echo "==> stapling"
  xcrun stapler staple "$DMG"
  spctl -a -vv -t install "$DMG" 2>&1 | tail -2
  echo "==> ticket check"
  xcrun stapler validate "$DMG"
  exit 0
fi

case "$IDENTITY" in
  "Developer ID"*)
    cat <<'NOTE'

To notarise (one-time credential setup, then per release):
  xcrun notarytool store-credentials cadviewer \
        --apple-id <appleid> --team-id <TEAMID> --password <app-specific-password>
  xcrun notarytool submit "$DMG" --keychain-profile cadviewer --wait
  xcrun stapler staple "$DMG"
NOTE
    ;;
esac
