#!/bin/bash
# Installs the built app and checks whether macOS actually activates the
# QuickLook thumbnail extension. Run this straight after a Developer ID build
# to settle whether signing was the blocker.
set -uo pipefail
cd "$(dirname "$0")/.."

APP=/Applications/CADViewer.app
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

echo "==> installing to /Applications"
rm -rf "$APP"
ditto build/CADViewer.app "$APP"
"$LSREG" -f "$APP"

echo "==> signature"
codesign -dv "$APP" 2>&1 | grep -E "Authority=|TeamIdentifier=" | head -3
echo "   notarised: $(spctl -a -vv "$APP" 2>&1 | grep -q "accepted" && echo yes || echo "no (Gatekeeper would warn)")"

echo "==> waiting for PlugInKit"
killall -9 pkd 2>/dev/null
# Registration is not immediate, and is not authoritative either: the thumbnail
# has been observed working while pluginkit still had nothing to say.
for i in 1 2 3 4 5 6; do
  sleep 4
  if pluginkit -mAv 2>/dev/null | grep -q -i cadviewer; then
    echo "   registered after ~$((i*4))s:"
    pluginkit -mAv 2>/dev/null | grep -i cadviewer | sed 's/^/     /'
    break
  fi
  [ "$i" = 6 ] && echo "   pluginkit has not listed it (may still work)"
done

echo "==> asking for a thumbnail the way Finder does"
if [ ! -x /tmp/qltest ]; then
  clang -fobjc-arc -framework Foundation -framework AppKit \
        -framework QuickLookThumbnailing tools/qltest.m -o /tmp/qltest 2>/dev/null
fi
RESULT=$(/tmp/qltest "$PWD/samples/plate.step" /tmp/ql_verify.png)
echo "   $RESULT"
case "$RESULT" in
  *"rendered thumbnail"*) echo; echo "PASS - Finder gets a real model thumbnail." ;;
  *) echo; echo "FAIL - still falling back to the generic icon."; exit 1 ;;
esac
