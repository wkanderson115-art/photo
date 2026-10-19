#!/usr/bin/env bash
# Run on a Mac with Xcode 26+. The resulting IPA still requires Apple signing.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]] || ! command -v xcodebuild >/dev/null 2>&1; then
  echo 'BUILD BLOCKED: macOS and full Xcode 26+ are required; Linux cannot build an iPhone app.' >&2
  exit 2
fi
SDK_VERSION=$(xcrun --sdk iphoneos --show-sdk-version)
if [[ "${SDK_VERSION%%.*}" -lt 26 ]]; then
  echo "BUILD BLOCKED: iOS 26+ SDK required; selected SDK is $SDK_VERSION." >&2
  exit 2
fi
mkdir -p build
for CONFIG in Debug Release; do
  xcodebuild \
    -project OutdoorPhotoAssistant.xcodeproj \
    -scheme OutdoorPhotoAssistant \
    -configuration "$CONFIG" \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "build/$CONFIG" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM="" \
    build 2>&1 | tee "build/build-$CONFIG.log"
done
APP='build/Release/Build/Products/Release-iphoneos/OutdoorPhotoAssistant.app'
test -d "$APP"
STAGING=$(mktemp -d "$PWD/build/ipa.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/Payload"
cp -R "$APP" "$STAGING/Payload/"
OUTPUT="$PWD/build/OutdoorPhotoAssistant-unsigned.ipa"
rm -f "$OUTPUT"
(cd "$STAGING" && /usr/bin/zip -qry "$OUTPUT" Payload)
echo "BUILT (UNSIGNED): $OUTPUT"
