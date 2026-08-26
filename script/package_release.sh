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

VERSION="${APPLE_PI_VERSION:-0.1.0}"
BUILD_NUMBER="${APPLE_PI_BUILD_NUMBER:-2}"
SIGNING_IDENTITY="${APPLE_PI_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${APPLE_PI_NOTARY_PROFILE:-}"
NOTARY_KEY="${APPLE_PI_NOTARY_KEY:-}"
NOTARY_KEY_ID="${APPLE_PI_NOTARY_KEY_ID:-}"
NOTARY_ISSUER_ID="${APPLE_PI_NOTARY_ISSUER_ID:-}"
SKIP_NOTARIZATION=false
HOST_APP_MAX_BYTES="${APPLE_PI_HOST_APP_MAX_BYTES:-15728640}"
ZIP_MAX_BYTES="${APPLE_PI_ZIP_MAX_BYTES:-20971520}"

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
  APPLE_PI_ZIP_MAX_BYTES      Release ZIP budget; defaults to 20 MiB
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

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "APPLE_PI_VERSION must be a three-component release version such as 0.1.0." >&2
  exit 64
fi

for numeric_value in "$BUILD_NUMBER" "$HOST_APP_MAX_BYTES" "$ZIP_MAX_BYTES"; do
  if [[ ! "$numeric_value" =~ ^[1-9][0-9]*$ ]]; then
    echo "Build numbers and artifact budgets must be positive integers." >&2
    exit 64
  fi
done

if [[ "$SIGNING_IDENTITY" != "Developer ID Application:"* ]]; then
  echo "APPLE_PI_SIGNING_IDENTITY must name a Developer ID Application identity." >&2
  exit 64
fi

signing_identities="$(/usr/bin/security find-identity -v -p codesigning 2>&1 || true)"
if [[ "$signing_identities" != *"\"$SIGNING_IDENTITY\""* ]]; then
  echo "The requested Developer ID Application identity is not available in the keychain:" >&2
  echo "  $SIGNING_IDENTITY" >&2
  /usr/bin/printf '%s\n' "$signing_identities" >&2
  exit 67
fi

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
/bin/cp "$ROOT_DIR/LICENSE" "$APP_BUNDLE/Contents/Resources/LICENSE.txt"
/bin/cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP_BUNDLE/Contents/Resources/THIRD_PARTY_NOTICES.md"
if [[ -e "$APP_BUNDLE/Contents/Resources/PiRuntime" ]]; then
  echo "Release artifacts must not contain a bundled Pi runtime." >&2
  exit 66
fi
/usr/bin/cmp "$ROOT_DIR/LICENSE" "$APP_BUNDLE/Contents/Resources/LICENSE.txt"
/usr/bin/cmp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP_BUNDLE/Contents/Resources/THIRD_PARTY_NOTICES.md"
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
  if [[ "$candidate" == "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ]]; then
    continue
  fi
  if /usr/bin/file -b "$candidate" | /usr/bin/grep -q 'Mach-O'; then
    codesign_item "$candidate"
  fi
done < <(/usr/bin/find "$APP_BUNDLE/Contents" -type f -print0)

while IFS= read -r nested_bundle; do
  codesign_item "$nested_bundle"
done < <(/usr/bin/find "$APP_BUNDLE/Contents" -depth -type d \( \
  -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.bundle' \
\) -print)

codesign_item "$APP_BUNDLE" \
  --entitlements "$ROOT_DIR/ApplePi/Resources/ApplePi.entitlements"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
/usr/bin/codesign -dvvv --entitlements :- "$APP_BUNDLE" >/dev/null
app_signature="$(/usr/bin/codesign -dvvv "$APP_BUNDLE" 2>&1)"
if [[ "$app_signature" != *'Authority=Developer ID Application:'* ]]; then
  echo "The app is not signed by a Developer ID Application identity." >&2
  exit 67
fi

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

notary_log() {
  local submission_id="$1"
  local destination="$2"
  if [[ -n "$NOTARY_PROFILE" ]]; then
    /usr/bin/xcrun notarytool log \
      --keychain-profile "$NOTARY_PROFILE" \
      --no-progress \
      "$submission_id" "$destination"
  else
    /usr/bin/xcrun notarytool log \
      --key "$NOTARY_KEY" \
      --key-id "$NOTARY_KEY_ID" \
      --issuer "$NOTARY_ISSUER_ID" \
      --no-progress \
      "$submission_id" "$destination"
  fi
}

notary_submit() {
  local artifact="$1"
  local label="$2"
  local result_path="$WORK_DIR/notary-$label-result.json"
  local accepted_log_path="$WORK_DIR/notary-$label-log.json"
  local log_path="$DIST_DIR/$APP_NAME-$VERSION-$label-notarization-log.json"
  local submit_status submission_id submission_status

  /bin/rm -f "$result_path" "$accepted_log_path" "$log_path"
  set +e
  if [[ -n "$NOTARY_PROFILE" ]]; then
    /usr/bin/xcrun notarytool submit "$artifact" \
      --keychain-profile "$NOTARY_PROFILE" \
      --wait \
      --output-format json >"$result_path"
    submit_status=$?
  else
    /usr/bin/xcrun notarytool submit "$artifact" \
      --key "$NOTARY_KEY" \
      --key-id "$NOTARY_KEY_ID" \
      --issuer "$NOTARY_ISSUER_ID" \
      --wait \
      --output-format json >"$result_path"
    submit_status=$?
  fi
  set -e

  if [[ -s "$result_path" ]]; then
    /bin/cat "$result_path"
  fi
  submission_id="$(/usr/bin/plutil -extract id raw -o - "$result_path" 2>/dev/null || true)"
  submission_status="$(/usr/bin/plutil -extract status raw -o - "$result_path" 2>/dev/null || true)"

  if [[ "$submit_status" -ne 0 || "$submission_status" != "Accepted" ]]; then
    if [[ -n "$submission_id" ]]; then
      if notary_log "$submission_id" "$log_path"; then
        echo "Notarization log: $log_path" >&2
      else
        echo "Notarization failed and its log could not be retrieved (submission $submission_id)." >&2
      fi
    else
      echo "Notarization failed before a submission ID was returned." >&2
    fi
    return 1
  fi

  if [[ -z "$submission_id" ]] || ! notary_log "$submission_id" "$accepted_log_path"; then
    echo "The accepted notarization submission log could not be retrieved." >&2
    return 1
  fi
  /bin/cat "$accepted_log_path"
}

/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
check_zip_budget

if [[ "$SKIP_NOTARIZATION" == false ]]; then
  # The ZIP is a notarization transport. After approval, recreate it so the
  # contained app also carries its stapled ticket for offline verification.
  notary_submit "$ZIP_PATH" zip
  /usr/bin/xcrun stapler staple "$APP_BUNDLE"
  /usr/bin/xcrun stapler validate "$APP_BUNDLE"
  /bin/rm -f "$ZIP_PATH"
  /usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
  check_zip_budget
fi

DMG_SOURCE="$WORK_DIR/$DISPLAY_NAME"
/bin/mkdir -p "$DMG_SOURCE"
/usr/bin/ditto "$APP_BUNDLE" "$DMG_SOURCE/$APP_NAME.app"
/bin/ln -s /Applications "$DMG_SOURCE/Applications"
/usr/sbin/diskutil image create from \
  --format UDZO \
  "$DMG_SOURCE" \
  "$DMG_PATH"

DMG_INFO="$WORK_DIR/dmg-info.plist"
/usr/sbin/diskutil image info --plist "$DMG_PATH" >"$DMG_INFO"
if [[ "$(/usr/bin/plutil -extract 'Image Format' raw -o - "$DMG_INFO")" != "UDZO" ]]; then
  echo "Release disk image was not created in UDZO format." >&2
  exit 66
fi
if [[ "$(/usr/bin/plutil -extract 'Partitions.3.volume-name' raw -o - "$DMG_INFO")" != "$DISPLAY_NAME" ]]; then
  echo "Release disk image has an unexpected volume name." >&2
  exit 66
fi

/usr/bin/codesign \
  --force \
  --timestamp \
  --sign "$SIGNING_IDENTITY" \
  "$DMG_PATH"
/usr/bin/codesign --verify --strict --verbose=2 "$DMG_PATH"

if [[ "$SKIP_NOTARIZATION" == false ]]; then
  notary_submit "$DMG_PATH" dmg
  /usr/bin/xcrun stapler staple "$DMG_PATH"
  /usr/bin/xcrun stapler validate "$DMG_PATH"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$APP_BUNDLE"
  /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
fi

(
  cd "$DIST_DIR"
  /usr/bin/shasum -a 256 "$(basename "$DMG_PATH")" "$(basename "$ZIP_PATH")" >SHA256SUMS
)

echo "Release artifacts:"
echo "  $DMG_PATH"
echo "  $ZIP_PATH"
echo "  $DIST_DIR/SHA256SUMS"
