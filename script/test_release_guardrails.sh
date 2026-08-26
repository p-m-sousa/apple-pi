#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_SCRIPT="$ROOT_DIR/script/package_release.sh"
TEMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/apple-pi-release-guards.XXXXXX")"
trap '/bin/rm -rf "$TEMP_DIR"' EXIT

expect_status() {
  local expected="$1"
  local label="$2"
  shift 2

  set +e
  "$@" >"$TEMP_DIR/$label.out" 2>&1
  local actual=$?
  set -e
  if [[ "$actual" -ne "$expected" ]]; then
    echo "$label returned $actual; expected $expected." >&2
    /bin/cat "$TEMP_DIR/$label.out" >&2
    exit 1
  fi
}

test ! -e "$ROOT_DIR/ApplePi/Resources/PiRuntime"
test ! -e "$ROOT_DIR/Config/PiRuntime.entitlements"
test ! -e "$ROOT_DIR/script/fetch_pi_runtime.sh"

expect_status 64 missing-identity \
  "$PACKAGE_SCRIPT" --skip-notarization
/usr/bin/grep -Fq 'APPLE_PI_SIGNING_IDENTITY is required' "$TEMP_DIR/missing-identity.out"

expect_status 64 malformed-version \
  /usr/bin/env \
    APPLE_PI_VERSION=0.1 \
    'APPLE_PI_SIGNING_IDENTITY=Developer ID Application: Test (TESTTEAM)' \
    "$PACKAGE_SCRIPT" --skip-notarization
/usr/bin/grep -Fq 'must be a three-component release version' "$TEMP_DIR/malformed-version.out"

expect_status 64 wrong-certificate-type \
  /usr/bin/env \
    'APPLE_PI_SIGNING_IDENTITY=Apple Development: Test (TESTTEAM)' \
    "$PACKAGE_SCRIPT" --skip-notarization
/usr/bin/grep -Fq 'must name a Developer ID Application identity' "$TEMP_DIR/wrong-certificate-type.out"

expect_status 67 unavailable-identity \
  /usr/bin/env \
    'APPLE_PI_SIGNING_IDENTITY=Developer ID Application: ApplePi Missing Test Identity (TESTTEAM)' \
    "$PACKAGE_SCRIPT" --skip-notarization
/usr/bin/grep -Fq 'is not available in the keychain' "$TEMP_DIR/unavailable-identity.out"

echo "Release guardrail checks passed."
