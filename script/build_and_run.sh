#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="ApplePi"
BUNDLE_ID="com.paulsousa.ApplePi"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="$ROOT_DIR/ApplePi.xcodeproj"
PROJECT_SPEC="$ROOT_DIR/project.yml"
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
    ;;
  *)
    usage
    exit 2
    ;;
esac

PROJECT_STALE=false
if [[ -d "$PROJECT_FILE" ]] && /usr/bin/find \
  "$ROOT_DIR/ApplePi" \
  "$ROOT_DIR/ApplePiTests" \
  "$ROOT_DIR/ApplePiUITests" \
  -type f -newer "$PROJECT_FILE/project.pbxproj" -print -quit 2>/dev/null | /usr/bin/grep -q .; then
  PROJECT_STALE=true
fi

if [[ ! -d "$PROJECT_FILE" || "$PROJECT_SPEC" -nt "$PROJECT_FILE/project.pbxproj" || "$PROJECT_STALE" == true ]]; then
  (cd "$ROOT_DIR" && "$ROOT_DIR/script/xcodegen.sh" generate)
fi

/usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true

/usr/bin/xcodebuild \
  -project "$PROJECT_FILE" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$ROOT_DIR/.build/SourcePackages" \
  -skipPackagePluginValidation \
  build

if [[ ! -x "$APP_BINARY" ]]; then
  echo "Build succeeded but the app executable was not found at $APP_BINARY" >&2
  exit 66
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    /usr/bin/lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      if /usr/bin/pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        exit 0
      fi
      /bin/sleep 0.25
    done
    echo "$APP_NAME did not remain running after launch." >&2
    exit 70
    ;;
esac
