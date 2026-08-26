#!/usr/bin/env bash
set -euo pipefail

PI_VERSION="0.84.2"
PI_ASSET="pi-darwin-arm64.tar.gz"
PI_SHA256="c996e888b7f7dce44bcf24f69176ac646c44139d3916bd49a6b28e5a8c5e3a65"
PI_URL="https://github.com/earendil-works/pi/releases/download/v${PI_VERSION}/${PI_ASSET}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS_DIR="$ROOT_DIR/.artifacts"
ARCHIVE_DIR="$ARTIFACTS_DIR/downloads"
ARCHIVE="$ARCHIVE_DIR/pi-${PI_VERSION}-${PI_ASSET}"
RUNTIME_DIR="$ARTIFACTS_DIR/pi-runtime-${PI_VERSION}"
RUNTIME_MARKER="$ARTIFACTS_DIR/.pi-runtime-${PI_VERSION}.archive-sha256"
FORCE_EXTRACT=false

if [[ "${1:-}" == "--force-extract" ]]; then
  FORCE_EXTRACT=true
elif [[ $# -ne 0 ]]; then
  echo "usage: $0 [--force-extract]" >&2
  exit 2
fi

if [[ "$(/usr/bin/uname -s)" != "Darwin" || "$(/usr/bin/uname -m)" != "arm64" ]]; then
  echo "The bundled Pi fallback is supported only on Apple-silicon macOS." >&2
  exit 69
fi

TEMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/apple-pi-runtime.XXXXXX")"
trap '/bin/rm -rf "$TEMP_DIR"' EXIT

DOWNLOADED_ARCHIVE="$TEMP_DIR/$PI_ASSET"
CONTENTS="$TEMP_DIR/contents.txt"
EXTRACTED="$TEMP_DIR/extracted"
STAGED="$TEMP_DIR/staged"

archive_sha() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

runtime_architectures_are_valid() {
  local candidate candidate_arch main_arch
  [[ -x "$1/pi" ]] || return 1
  main_arch="$(/usr/bin/lipo -archs "$1/pi" 2>/dev/null || true)"
  [[ "$main_arch" == "arm64" ]] || return 1

  while IFS= read -r -d '' candidate; do
    if /usr/bin/file -b "$candidate" | /usr/bin/grep -q 'Mach-O'; then
      candidate_arch="$(/usr/bin/lipo -archs "$candidate" 2>/dev/null || true)"
      [[ "$candidate_arch" == "arm64" ]] || return 1
    fi
  done < <(/usr/bin/find "$1" -type f -print0)
}

/bin/mkdir -p "$ARCHIVE_DIR"
if [[ -f "$ARCHIVE" ]]; then
  cached_sha="$(archive_sha "$ARCHIVE")"
  if [[ "$cached_sha" != "$PI_SHA256" ]]; then
    echo "Cached Pi archive checksum mismatch; downloading a verified replacement." >&2
    /bin/rm -f "$ARCHIVE"
  fi
fi

if [[ ! -f "$ARCHIVE" ]]; then
  /usr/bin/curl \
    --fail \
    --location \
    --proto '=https' \
    --retry 3 \
    --show-error \
    --silent \
    --tlsv1.2 \
    --output "$DOWNLOADED_ARCHIVE" \
    "$PI_URL"

  actual_sha="$(archive_sha "$DOWNLOADED_ARCHIVE")"
  if [[ "$actual_sha" != "$PI_SHA256" ]]; then
    echo "Pi runtime checksum mismatch." >&2
    echo "expected: $PI_SHA256" >&2
    echo "actual:   $actual_sha" >&2
    exit 65
  fi
  /bin/mv "$DOWNLOADED_ARCHIVE" "$ARCHIVE"
fi

actual_sha="$(archive_sha "$ARCHIVE")"
if [[ "$actual_sha" != "$PI_SHA256" ]]; then
  echo "Verified Pi archive became invalid before extraction." >&2
  exit 65
fi

if [[ "$FORCE_EXTRACT" == false && -f "$RUNTIME_MARKER" ]]; then
  marker_sha="$(/bin/cat "$RUNTIME_MARKER")"
  if [[ "$marker_sha" == "$PI_SHA256" ]] && runtime_architectures_are_valid "$RUNTIME_DIR"; then
    echo "$RUNTIME_DIR"
    exit 0
  fi
  echo "Cached Pi runtime validation failed; rebuilding it from the verified archive." >&2
fi

/usr/bin/tar -tzf "$ARCHIVE" >"$CONTENTS"
if /usr/bin/awk '
  /^\// { print; next }
  /(^|\/)\.\.($|\/)/ { print; next }
  $0 != "pi" && $0 !~ /^pi\// { print }
' "$CONTENTS" | /usr/bin/grep -q .; then
  echo "Pi runtime archive contains an unsafe or unexpected path." >&2
  exit 65
fi

/bin/mkdir -p "$EXTRACTED"
/usr/bin/tar -xzf "$ARCHIVE" -C "$EXTRACTED"

if [[ ! -x "$EXTRACTED/pi/pi" ]]; then
  echo "Pi runtime archive does not contain the expected pi/pi executable." >&2
  exit 65
fi

if ! runtime_architectures_are_valid "$EXTRACTED/pi"; then
  echo "The Pi runtime contains a missing or non-arm64 Mach-O executable." >&2
  exit 65
fi

/usr/bin/ditto "$EXTRACTED/pi" "$STAGED"
/bin/chmod +x "$STAGED/pi"
/bin/mkdir -p "$ARTIFACTS_DIR"
/bin/rm -rf "$RUNTIME_DIR"
/bin/mv "$STAGED" "$RUNTIME_DIR"
/usr/bin/printf '%s\n' "$PI_SHA256" >"$TEMP_DIR/runtime-marker"
/bin/mv "$TEMP_DIR/runtime-marker" "$RUNTIME_MARKER"

echo "$RUNTIME_DIR"
