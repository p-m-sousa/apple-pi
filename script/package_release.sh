#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ApplePi"
DISPLAY_NAME="ApplePi"
BUNDLE_ID="com.paulsousa.ApplePi"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="$ROOT_DIR/ApplePi.xcodeproj"
ARCHIVE_PATH="$ROOT_DIR/.build/release/$APP_NAME.xcarchive"
WORK_DIR="$ROOT_DIR/.build/release/staging"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$WORK_DIR/$APP_NAME.app"
RUNTIME_DESTINATION="$APP_BUNDLE/Contents/Resources/PiRuntime"

VERSION="${APPLE_PI_VERSION:-0.1.0}"
BUILD_NUMBER="${APPLE_PI_BUILD_NUMBER:-2}"
SIGNING_IDENTITY="${APPLE_PI_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${APPLE_PI_NOTARY_PROFILE:-}"
NOTARY_KEY="${APPLE_PI_NOTARY_KEY:-}"
NOTARY_KEY_ID="${APPLE_PI_NOTARY_KEY_ID:-}"
NOTARY_ISSUER_ID="${APPLE_PI_NOTARY_ISSUER_ID:-}"
SKIP_NOTARIZATION=false
HOST_APP_MAX_BYTES="${APPLE_PI_HOST_APP_MAX_BYTES:-15728640}"
ZIP_MAX_BYTES="${APPLE_PI_ZIP_MAX_BYTES:-41943040}"

usage() {
  cat >&2 <<'USAGE'
usage: script/package_release.sh [--skip-notarization]

Required environment:
  APPLE_PI_SIGNING_IDENTITY   Developer ID Application identity

Notarization uses either:
  APPLE_PI_NOTARY_PROFILE
or all of:
  APPLE_PI_NOTARY_KEY, APPLE_PI_NOTARY_KEY_ID, APPLE_PI_NOTARY_ISSUER_ID

Optional:
  APPLE_PI_VERSION            Defaults to 0.1.0
  APPLE_PI_BUILD_NUMBER       Positive integer; defaults to 2
  APPLE_PI_HOST_APP_MAX_BYTES Host app budget; defaults to 15 MiB
  APPLE_PI_ZIP_MAX_BYTES      Release ZIP budget; defaults to 40 MiB
USAGE
}

if [[ "${1:-}" == "--skip-notarization" ]]; then
  SKIP_NOTARIZATION=true
elif [[ $# -ne 0 ]]; then
  usage
  exit 2
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
  usage
  echo "APPLE_PI_SIGNING_IDENTITY is required." >&2
  exit 64
fi

if [[ "$SKIP_NOTARIZATION" == false && -z "$NOTARY_PROFILE" ]]; then
  if [[ -z "$NOTARY_KEY" || -z "$NOTARY_KEY_ID" || -z "$NOTARY_ISSUER_ID" ]]; then
    usage
    echo "Notarization credentials are required unless --skip-notarization is used." >&2
    exit 64
  fi
fi

case "$VERSION" in
  *[!0-9A-Za-z.-]*|'')
    echo "APPLE_PI_VERSION contains unsupported characters: $VERSION" >&2
    exit 64
    ;;
esac

for numeric_value in "$BUILD_NUMBER" "$HOST_APP_MAX_BYTES" "$ZIP_MAX_BYTES"; do
  if [[ ! "$numeric_value" =~ ^[1-9][0-9]*$ ]]; then
    echo "Build numbers and artifact budgets must be positive integers." >&2
    exit 64
  fi
done

RUNTIME_DIR="$("$ROOT_DIR/script/fetch_pi_runtime.sh" --force-extract)"

(cd "$ROOT_DIR" && "$ROOT_DIR/script/xcodegen.sh" generate)

/bin/rm -rf "$ARCHIVE_PATH" "$WORK_DIR"
/bin/mkdir -p "$WORK_DIR" "$DIST_DIR"
/bin/rm -f \
  "$DIST_DIR/$APP_NAME-$VERSION.dmg" \
  "$DIST_DIR/$APP_NAME-$VERSION.zip" \
  "$DIST_DIR/SHA256SUMS"

/usr/bin/xcodebuild \
  -project "$PROJECT_FILE" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  -clonedSourcePackagesDirPath "$ROOT_DIR/.build/SourcePackages" \
  -skipPackagePluginValidation \
  ARCHS=arm64 \
  ENABLE_CODE_COVERAGE=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO \
  archive

ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
if [[ ! -d "$ARCHIVED_APP" ]]; then
  echo "Archive did not produce $ARCHIVED_APP" >&2
  exit 66
fi

host_app_kib="$(/usr/bin/du -sk "$ARCHIVED_APP" | /usr/bin/awk '{print $1}')"
host_app_bytes="$((host_app_kib * 1024))"
if (( host_app_bytes > HOST_APP_MAX_BYTES )); then
  echo "Host app exceeds its size budget: $host_app_bytes > $HOST_APP_MAX_BYTES bytes" >&2
  exit 66
fi
echo "Host app size: $host_app_bytes bytes (budget: $HOST_APP_MAX_BYTES)"

/usr/bin/ditto "$ARCHIVED_APP" "$APP_BUNDLE"
/bin/mkdir -p "$APP_BUNDLE/Contents/Resources"
/usr/bin/ditto "$RUNTIME_DIR" "$RUNTIME_DESTINATION"
/bin/cp "$ROOT_DIR/LICENSE" "$APP_BUNDLE/Contents/Resources/LICENSE.txt"
/bin/cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP_BUNDLE/Contents/Resources/THIRD_PARTY_NOTICES.md"
/usr/bin/xattr -cr "$APP_BUNDLE"

codesign_item() {
  local item="$1"
  shift
  /usr/bin/codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$@" \
    "$item"
}

# Sign every nested Mach-O before its containing bundle. SwiftPM dependencies are
# currently linked statically, but this also handles future dynamic frameworks.
while IFS= read -r -d '' candidate; do
  if [[ "$candidate" == "$APP_BUNDLE/Contents/MacOS/$APP_NAME" || "$candidate" == "$RUNTIME_DESTINATION/pi" ]]; then
    continue
  fi
  if /usr/bin/file -b "$candidate" | /usr/bin/grep -q 'Mach-O'; then
    codesign_item "$candidate"
  fi
done < <(/usr/bin/find "$APP_BUNDLE/Contents" -type f -print0)

codesign_item "$RUNTIME_DESTINATION/pi" \
  --entitlements "$ROOT_DIR/Config/PiRuntime.entitlements"

while IFS= read -r nested_bundle; do
  codesign_item "$nested_bundle"
done < <(/usr/bin/find "$APP_BUNDLE/Contents" -depth -type d \( \
  -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.bundle' \
\) -print)

codesign_item "$APP_BUNDLE" \
  --entitlements "$ROOT_DIR/ApplePi/Resources/ApplePi.entitlements"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
/usr/bin/codesign -dvvv --entitlements :- "$APP_BUNDLE" >/dev/null
/usr/bin/codesign -dvvv --entitlements :- "$RUNTIME_DESTINATION/pi" >/dev/null

ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION.zip"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"

check_zip_budget() {
  local zip_bytes
  zip_bytes="$(/usr/bin/stat -f '%z' "$ZIP_PATH")"
  if (( zip_bytes > ZIP_MAX_BYTES )); then
    echo "Release ZIP exceeds its size budget: $zip_bytes > $ZIP_MAX_BYTES bytes" >&2
    exit 66
  fi
  echo "Release ZIP size: $zip_bytes bytes (budget: $ZIP_MAX_BYTES)"
}

notary_submit() {
  local artifact="$1"
  if [[ -n "$NOTARY_PROFILE" ]]; then
    /usr/bin/xcrun notarytool submit "$artifact" \
      --keychain-profile "$NOTARY_PROFILE" \
      --wait
  else
    /usr/bin/xcrun notarytool submit "$artifact" \
      --key "$NOTARY_KEY" \
      --key-id "$NOTARY_KEY_ID" \
      --issuer "$NOTARY_ISSUER_ID" \
      --wait
  fi
}

/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
check_zip_budget

if [[ "$SKIP_NOTARIZATION" == false ]]; then
  # The ZIP is a notarization transport. After approval, recreate it so the
  # contained app also carries its stapled ticket for offline verification.
  notary_submit "$ZIP_PATH"
  /usr/bin/xcrun stapler staple "$APP_BUNDLE"
  /usr/bin/xcrun stapler validate "$APP_BUNDLE"
  /bin/rm -f "$ZIP_PATH"
  /usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
  check_zip_budget
fi

DMG_SOURCE="$WORK_DIR/dmg"
/bin/mkdir -p "$DMG_SOURCE"
/usr/bin/ditto "$APP_BUNDLE" "$DMG_SOURCE/$APP_NAME.app"
/bin/ln -s /Applications "$DMG_SOURCE/Applications"
/usr/bin/hdiutil create \
  -volname "$DISPLAY_NAME" \
  -srcfolder "$DMG_SOURCE" \
  -format UDZO \
  -ov \
  "$DMG_PATH"

if [[ "$SKIP_NOTARIZATION" == false ]]; then
  notary_submit "$DMG_PATH"
  /usr/bin/xcrun stapler staple "$DMG_PATH"
  /usr/bin/xcrun stapler validate "$DMG_PATH"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$APP_BUNDLE"
  /usr/sbin/spctl --assess --type open --verbose=2 "$DMG_PATH"
fi

(
  cd "$DIST_DIR"
  /usr/bin/shasum -a 256 "$(basename "$DMG_PATH")" "$(basename "$ZIP_PATH")" >SHA256SUMS
)

echo "Release artifacts:"
echo "  $DMG_PATH"
echo "  $ZIP_PATH"
echo "  $DIST_DIR/SHA256SUMS"
