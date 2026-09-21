#!/usr/bin/env bash

set -euo pipefail

# Usage: ./scripts/ios-simulator-check.sh [--stage | --server-url URL] [--device NAME]
#
# Boots an iPhone simulator, installs the shell and exercises what only exists at
# runtime: does it launch, does the site paint, does it survive a relaunch.
# Screenshots land in dist/ios-sim/.
# See docs/architecture/ios-app.md.
#
# A simulator build is never signed, so this needs macOS but no certificate,
# no provisioning profile and no registered device — it runs before any of that
# exists, and is the only verification available without borrowing an iPhone.
#
# What it cannot do, and no simulator can:
#   - Anything about push. `simctl push` delivers a payload, but iOS shows
#     nothing without notification permission, and that is only requested inside
#     registerForPush() after login — which CI cannot do. A push step here is
#     indistinguishable from a no-op, so there isn't one.
#   - A cold deep link. `simctl openurl` raises iOS's "Open in ...?" prompt and
#     nothing can tap it, so consumeLaunchUrl() stays unverified — the step only
#     proves the scheme is registered to this app. It runs LAST because that
#     prompt stays on screen and would otherwise sit over every later shot.
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

PREV_SHOT=""

shoot() {
  local name="$1"
  local path="$OUT_DIR/$name.png"
  xcrun simctl io "$UDID" screenshot "$path" >/dev/null 2>&1

  local bytes
  bytes="$(stat -f%z "$path" 2>/dev/null || echo 0)"
  printf '  %-22s %7s bytes' "$name.png" "$bytes"

  # A white screen is the failure this script exists to catch, and it compresses
  # to almost nothing next to a rendered page.
  if [ "$bytes" -lt 20000 ]; then
    echo "  ⚠️  suspiciously blank"
  # Byte-identical to the shot before it means the step changed nothing on
  # screen. That is how a step can pass while proving nothing, so say it loudly.
  elif [ -n "$PREV_SHOT" ] && cmp -s "$PREV_SHOT" "$path"; then
    echo "  ⚠️  identical to $(basename "$PREV_SHOT") — step changed nothing"
  else
    echo
  fi

  PREV_SHOT="$path"
}

echo
echo "Cold launch"
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
sleep 12
shoot "01-launch"

echo
echo "Relaunch (cookie persistence across a cold start)"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
sleep 2
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
sleep 10
shoot "02-relaunch"

echo
echo "URL scheme registration ($DEEP_LINK)"
# Last, and deliberately so: this raises an "Open in ...?" prompt that nothing
# can dismiss, and it would sit over every screenshot taken after it. A shot
# showing that prompt naming this app is the whole result — iOS resolved the
# scheme to us. Whether consumeLaunchUrl() then routes correctly needs a device.
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
sleep 2
xcrun simctl openurl "$UDID" "$DEEP_LINK"
sleep 6
shoot "03-scheme-prompt"

echo
echo "✅ Screenshots: $OUT_DIR/"
echo
echo "01 and 02 prove the shell runs and paints. 03 only proves the scheme is"
echo "registered — a cold deep link, anything about push, and a signed install"
echo "all still need a real device. See docs/architecture/ios-app.md."
