#!/usr/bin/env bash

set -euo pipefail

# Usage: ./scripts/ios-simulator-check.sh [--stage | --server-url URL] [--device NAME]
#
# Boots an iPhone simulator, installs the shell and exercises what only exists at
# runtime: does it launch, does the site paint, does a cold deep link land, does a
# push payload get handled without crashing. Screenshots land in dist/ios-sim/.
# See docs/architecture/ios-app.md.
#
# A simulator build is never signed, so this needs macOS but no certificate,
# no provisioning profile and no registered device — it runs before any of that
# exists, and is the only verification available without borrowing an iPhone.
#
# What it cannot do, and no simulator can:
#   - APNs registration. `simctl push` injects a payload locally; it does not
#     mint a device token, so the `registerForPush()` fork stays unverified.
#   - A notification *tap*. The payload is delivered, but nothing can tap the
#     banner from a CLI, so `data.link` -> toNotificationPath() is still only
#     covered by src/native/routing.test.ts.
#   - Prove a signed .ipa installs on hardware. Different code path entirely.

SERVER_URL="https://web.raghamapp.com"
DEVICE="iPhone 16 Pro"
BUNDLE_ID="com.raghamapp.app"
DEEP_LINK="raghamapp://invoices"

while [ $# -gt 0 ]; do
  case "$1" in
    --stage)
      SERVER_URL="https://beta.raghamapp.com"
      shift
      ;;
    --server-url)
      SERVER_URL="${2:-}"
      if [ -z "$SERVER_URL" ]; then
        echo "Error: --server-url needs a value." >&2
        exit 1
      fi
      shift 2
      ;;
    --device)
      DEVICE="${2:-}"
      if [ -z "$DEVICE" ]; then
        echo "Error: --device needs a value." >&2
        exit 1
      fi
      shift 2
      ;;
    *)
      echo "Error: unknown argument '$1'. Use --stage, --server-url URL or --device NAME." >&2
      exit 1
      ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Error: a simulator only exists on macOS with Xcode installed." >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Error: xcodebuild not found. Install Xcode and run:" >&2
  echo "  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

cd "$(dirname "$0")/.."

if [ ! -d "node_modules/@capacitor/cli" ]; then
  echo "Error: @capacitor/cli is missing. Run 'npm ci' (not 'npm ci --omit=dev')." >&2
  exit 1
fi

OUT_DIR="dist/ios-sim"
DERIVED_DATA="$OUT_DIR/DerivedData"

if command -v python3 >/dev/null 2>&1; then
  PREFLIGHT_ARGS=""
  [ -d "src/native" ] || PREFLIGHT_ARGS="--native-only"
  python3 scripts/ios-preflight.py $PREFLIGHT_ARGS || {
    echo >&2
    echo "Preflight failed — fix the above before building." >&2
    exit 1
  }
  echo
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "Ragham iOS simulator check"
echo "  shell points at: $SERVER_URL"
XCODE_VERSION="$(xcodebuild -version)"
echo "  ${XCODE_VERSION%%$'\n'*}"

CAP_SERVER_URL="$SERVER_URL" npx cap sync ios

# Resolve the device by name, falling back to the newest available iPhone. A
# runner image bump renames these, and a hard-coded name that vanished would
# fail here rather than anywhere informative.
UDID="$(xcrun simctl list devices available -j \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)['devices']
wanted = sys.argv[1]
iphones = [d for runtime in data.values() for d in runtime if d['name'].startswith('iPhone')]
match = [d for d in iphones if d['name'] == wanted]
picked = (match or iphones[-1:] or [None])[0]
print(picked['udid'] if picked else '')
" "$DEVICE")"

if [ -z "$UDID" ]; then
  echo "Error: no iPhone simulator available. 'xcrun simctl list devices available' is empty." >&2
  exit 1
fi

RESOLVED="$(xcrun simctl list devices available | grep "$UDID" | sed 's/ (.*//;s/^ *//')"
echo "  simulator: $RESOLVED"
echo

cleanup() { xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

xcodebuild build \
  -project ios/App/App.xcodeproj \
  -scheme App \
  -configuration Release \
  -sdk iphonesimulator \
  -destination "id=$UDID" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS=""

APP_PATH="$DERIVED_DATA/Build/Products/Release-iphonesimulator/App.app"
if [ ! -d "$APP_PATH" ]; then
  echo "Error: build produced no App.app at $APP_PATH" >&2
  exit 1
fi

xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$APP_PATH"

shoot() {
  local name="$1"
  xcrun simctl io "$UDID" screenshot "$OUT_DIR/$name.png" >/dev/null 2>&1
  # A white screen is the failure this whole script exists to catch, and it
  # compresses to almost nothing next to a rendered page.
  local bytes
  bytes="$(stat -f%z "$OUT_DIR/$name.png" 2>/dev/null || echo 0)"
  printf '  %-22s %7s bytes' "$name.png" "$bytes"
  if [ "$bytes" -lt 20000 ]; then
    echo "  ⚠️  suspiciously blank"
  else
    echo
  fi
}

echo
echo "Cold launch"
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
sleep 12
shoot "01-launch"

echo
echo "Cold deep link ($DEEP_LINK)"
# Terminated first on purpose: appUrlOpen only fires while the shell already
# runs, so a link that *launches* the app goes through consumeLaunchUrl(), and
# that is the path with no test coverage and the easy bug.
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
sleep 2
xcrun simctl openurl "$UDID" "$DEEP_LINK"
sleep 10
shoot "02-deeplink-cold"

echo
echo "Push payload delivery"
cat > "$OUT_DIR/payload.apns" <<JSON
{
  "Simulator Target Bundle": "$BUNDLE_ID",
  "aps": { "alert": { "title": "تست", "body": "اعلان آزمایشی" }, "sound": "default" },
  "data": { "link": "/invoices" }
}
JSON
xcrun simctl push "$UDID" "$BUNDLE_ID" "$OUT_DIR/payload.apns" >/dev/null
sleep 5
shoot "03-push-delivered"

echo
echo "Relaunch (cookie persistence across a cold start)"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
sleep 2
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
sleep 10
shoot "04-relaunch"

echo
echo "✅ Screenshots: $OUT_DIR/"
echo
echo "These prove the shell runs and paints. Push registration and a signed"
echo "install still need a real device — see docs/architecture/ios-app.md."
