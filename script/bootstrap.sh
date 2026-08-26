#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -ne 0 ]]; then
  echo "usage: $0" >&2
  exit 2
fi

(cd "$ROOT_DIR" && "$ROOT_DIR/script/xcodegen.sh" generate)

/usr/bin/xcodebuild \
  -resolvePackageDependencies \
  -project "$ROOT_DIR/ApplePi.xcodeproj" \
  -scheme ApplePi \
  -clonedSourcePackagesDirPath "$ROOT_DIR/.build/SourcePackages" \
  -skipPackagePluginValidation

echo "ApplePi bootstrap complete."
