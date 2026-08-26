#!/usr/bin/env bash
set -euo pipefail

XCODEGEN_VERSION="2.45.4"
XCODEGEN_ARCHIVE_SHA256="090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef"
XCODEGEN_BINARY_SHA256="6aa2b4da95304b343bea12890c59f9655aa428c08b351d57d592cfab4e88a9f1"
XCODEGEN_URL="https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT_DIR/.build/tools"
INSTALL_DIR="$TOOLS_DIR/xcodegen-$XCODEGEN_VERSION"
XCODEGEN_BIN="$INSTALL_DIR/bin/xcodegen"

sha256() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

installed_tool_is_valid() {
  [[ -x "$XCODEGEN_BIN" ]] || return 1
  [[ "$(sha256 "$XCODEGEN_BIN")" == "$XCODEGEN_BINARY_SHA256" ]] || return 1
  [[ "$($XCODEGEN_BIN --version)" == "Version: $XCODEGEN_VERSION" ]]
}

if ! installed_tool_is_valid; then
  TEMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/apple-pi-xcodegen.XXXXXX")"
  trap '/bin/rm -rf "$TEMP_DIR"' EXIT

  ARCHIVE="$TEMP_DIR/xcodegen.zip"
  EXTRACTED="$TEMP_DIR/extracted"
  /usr/bin/curl \
    --fail \
    --location \
    --proto '=https' \
    --retry 3 \
    --show-error \
    --silent \
    --tlsv1.2 \
    --output "$ARCHIVE" \
    "$XCODEGEN_URL"

  actual_archive_sha="$(sha256 "$ARCHIVE")"
  if [[ "$actual_archive_sha" != "$XCODEGEN_ARCHIVE_SHA256" ]]; then
    echo "XcodeGen archive checksum mismatch." >&2
    echo "expected: $XCODEGEN_ARCHIVE_SHA256" >&2
    echo "actual:   $actual_archive_sha" >&2
    exit 65
  fi

  /bin/mkdir -p "$EXTRACTED"
  /usr/bin/unzip -q "$ARCHIVE" -d "$EXTRACTED"
  extracted_bin="$EXTRACTED/xcodegen/bin/xcodegen"
  if [[ ! -x "$extracted_bin" ]]; then
    echo "The XcodeGen archive did not contain xcodegen/bin/xcodegen." >&2
    exit 65
  fi
  if [[ "$(sha256 "$extracted_bin")" != "$XCODEGEN_BINARY_SHA256" ]]; then
    echo "The extracted XcodeGen binary checksum is invalid." >&2
    exit 65
  fi
  if [[ "$($extracted_bin --version)" != "Version: $XCODEGEN_VERSION" ]]; then
    echo "The extracted XcodeGen binary reported an unexpected version." >&2
    exit 65
  fi

  /bin/mkdir -p "$TOOLS_DIR"
  /bin/rm -rf "$INSTALL_DIR"
  /bin/mv "$EXTRACTED/xcodegen" "$INSTALL_DIR"
fi

exec "$XCODEGEN_BIN" "$@"
