#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DERIVED_DATA_PATH="${APPLE_PI_TEST_DERIVED_DATA_PATH:-.build/DerivedData}"
SOURCE_PACKAGES_PATH="${APPLE_PI_TEST_SOURCE_PACKAGES_PATH:-.build/SourcePackages}"
DESTINATION="${APPLE_PI_TEST_DESTINATION:-platform=macOS,arch=$(/usr/bin/uname -m)}"
CONFIGURATION="${APPLE_PI_TEST_CONFIGURATION:-Debug}"
CODE_COVERAGE="${APPLE_PI_TEST_ENABLE_CODE_COVERAGE:-YES}"

common_arguments=(
  -project ApplePi.xcodeproj
  -scheme ApplePi
  -testPlan ApplePi
  -configuration "$CONFIGURATION"
  -destination "$DESTINATION"
  -derivedDataPath "$DERIVED_DATA_PATH"
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_PATH"
  -skipPackagePluginValidation
  -parallel-testing-enabled NO
  -enableCodeCoverage "$CODE_COVERAGE"
)
if [[ "${APPLE_PI_TEST_QUIET:-0}" == "1" ]]; then
  common_arguments=(-quiet "${common_arguments[@]}")
fi

echo "Running scheduler-sensitive runtime coordinator tests in isolation."
/usr/bin/xcodebuild \
  "${common_arguments[@]}" \
  -only-testing:ApplePiTests/RuntimeCoordinatorTests \
  test

echo "Running all remaining unit and UI tests."
/usr/bin/xcodebuild \
  "${common_arguments[@]}" \
  -skip-testing:ApplePiTests/RuntimeCoordinatorTests \
  test
