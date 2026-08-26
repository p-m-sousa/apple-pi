#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WITH_RUNTIME=false

if [[ "${1:-}" == "--with-runtime" ]]; then
  WITH_RUNTIME=true
elif [[ $# -ne 0 ]]; then
  echo "usage: $0 [--with-runtime]" >&2
  exit 2
fi

(cd "$ROOT_DIR" && "$ROOT_DIR/script/xcodegen.sh" generate)

/usr/bin/xcodebuild \
  -resolvePackageDependencies \
  -project "$ROOT_DIR/ApplePi.xcodeproj" \
  -scheme ApplePi \
  -clonedSourcePackagesDirPath "$ROOT_DIR/.build/SourcePackages" \
  -skipPackagePluginValidation

if [[ "$WITH_RUNTIME" == true ]]; then
  "$ROOT_DIR/script/fetch_pi_runtime.sh"
fi

echo "ApplePi bootstrap complete."
