#!/usr/bin/env bash

set -euo pipefail

# Usage: ./scripts/ios-archive.sh [--stage | --server-url URL]
#
# Builds the iOS shell and writes an UNSIGNED .ipa to dist/ios/.
# See docs/architecture/ios-app.md.
#
# Unsigned is the default because we have no Apple developer account: the market
# re-signs what we hand over. `xcodebuild -exportArchive` refuses to export
# without a signing identity, so the archive is built with signing switched off
# and the .ipa assembled by hand — an .ipa is just a zip with the .app inside a
# Payload/ directory, which is exactly what a re-signer expects.
#
# The version invariant from deploy.sh holds here too:
#
#   package.json "version" == git tag vX.Y.Z == CFBundleShortVersionString
#
# so a user reporting "نسخه X.Y.Z" resolves to one commit on iOS as well.

SERVER_URL="https://web.raghamapp.com"

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
    *)
      echo "Error: unknown argument '$1'. Use --stage or --server-url URL." >&2
      exit 1
      ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Error: an .ipa can only be produced on macOS with Xcode installed." >&2
  echo "Everything else — the Xcode project, icons, config — is generated on any" >&2
  echo "platform by 'npx cap sync ios'. Only this last step needs a Mac." >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Error: xcodebuild not found. Install Xcode and run:" >&2
  echo "  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

cd "$(dirname "$0")/.."

if [ ! -f "package.json" ]; then
  echo "Error: package.json not found." >&2
  exit 1
fi

if [ ! -d "node_modules/@capacitor/cli" ]; then
  echo "Error: @capacitor/cli is missing. Run 'npm ci' (not 'npm ci --omit=dev')." >&2
  exit 1
fi

VERSION="$(node -p "require('./package.json').version")"
if [ -z "$VERSION" ] || [ "$VERSION" = "undefined" ]; then
  echo "Error: could not read version from package.json." >&2
  exit 1
fi

# Must increase with every submission. The commit count is monotonic and needs
# no state of its own; a shallow clone falls back to 1. The override exists for
# the public export built on GitHub's macOS runners (scripts/ios-shell-export.sh),
# whose repository has a history of its own that restarts at 1.
BUILD_NUMBER="${IOS_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

OUT_DIR="dist/ios"
DERIVED_DATA="$OUT_DIR/DerivedData"
IPA_PATH="$OUT_DIR/Ragham-$VERSION.ipa"

if command -v python3 >/dev/null 2>&1; then
  # Two checks read src/, which the public export does not carry. There they
  # ran already, at export time, against the real tree.
  PREFLIGHT_ARGS=""
  [ -d "src/native" ] || PREFLIGHT_ARGS="--native-only"

  python3 scripts/ios-preflight.py $PREFLIGHT_ARGS || {
    echo >&2
    echo "Preflight failed — fix the above before building; each of those" >&2
    echo "produces a broken app with no error message at build time." >&2
    exit 1
  }
  echo
fi

echo "Building Ragham iOS $VERSION (build $BUILD_NUMBER)"
echo "  shell points at: $SERVER_URL"
xcodebuild -version | head -1
echo

# Writes ios/App/App/capacitor.config.json, which is what the app actually reads
# at runtime — editing capacitor.config.ts without syncing changes nothing.
CAP_SERVER_URL="$SERVER_URL" npx cap sync ios

rm -rf "$DERIVED_DATA" "$IPA_PATH"
mkdir -p "$OUT_DIR"

# A plain `build`, not `archive`, on purpose. `xcodebuild archive` runs a signing
# and validation step that fails without an identity — and fails harder with an
# entitlements file present. Building the product directly and packaging it by
# hand is the path that works with no signing identity at all. Entitlements are
# blanked for the same reason; the market's re-signing applies its own, and
# `App.entitlements` stays in the project for whenever we do sign in-house.
xcodebuild build \
  -project ios/App/App.xcodeproj \
  -scheme App \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "$DERIVED_DATA" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS=""

APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/App.app"
if [ ! -d "$APP_PATH" ]; then
  echo "Error: build produced no App.app at $APP_PATH" >&2
  echo "Look above for the real xcodebuild failure." >&2
  exit 1
fi

# Assert the build actually carries the identity we think it does, rather than
# discovering it after the market has signed and shipped it.
PLIST="$APP_PATH/Info.plist"
BUILT_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST")"
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"

if [ "$BUILT_ID" != "com.raghamapp.app" ]; then
  echo "Error: built bundle id is '$BUILT_ID', expected com.raghamapp.app." >&2
  exit 1
fi
if [ "$BUILT_VERSION" != "$VERSION" ]; then
  echo "Error: built version is '$BUILT_VERSION', expected $VERSION." >&2
  exit 1
fi
if [ ! -f "$APP_PATH/App" ]; then
  echo "Error: no executable inside App.app." >&2
  exit 1
fi

echo "  bundle id: $BUILT_ID"
echo "  version:   $BUILT_VERSION ($BUILD_NUMBER)"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

mkdir -p "$STAGING/Payload"
cp -R "$APP_PATH" "$STAGING/Payload/"
(cd "$STAGING" && zip -qry "payload.zip" Payload -x "*.DS_Store")
mv "$STAGING/payload.zip" "$IPA_PATH"

echo
echo "✅ Unsigned IPA: $IPA_PATH"
echo
echo "Next: hand this to the market for signing. If you ever sign in-house"
echo "instead, re-run with signing enabled and restore CODE_SIGN_ENTITLEMENTS"
echo "so the aps-environment entitlement (push) survives — see"
echo "docs/architecture/ios-app.md."
