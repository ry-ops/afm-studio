#!/usr/bin/env bash
# Writes the App Intents metadata into AFM Studio.app, so Siri, Shortcuts and Spotlight can see its actions.
#   bash scripts/app-intents-metadata.sh "build/AFM Studio.app"   (build-app.sh runs this for you)
#
# `swift build` already compiles the intents and records what they declare. The last step, turning that
# into Contents/Resources/Metadata.appintents, needs Apple's appintentsmetadataprocessor, which ships
# with Xcode and not with the Command Line Tools. Without Xcode the app still builds and runs, but
# macOS won't list its Siri actions. Install Xcode (it can stay unselected) and rebuild to add them.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?usage: app-intents-metadata.sh <path to AFM Studio.app>}"
CONFIG="${CONFIG:-release}"
MODULE=AFMStudio
BUNDLE_ID=dev.ry-ops.afm-studio
DEPLOYMENT_TARGET=$(sed -n 's/.*platforms: \[\.macOS("\([0-9.]*\)")\].*/\1/p' Package.swift)

# The tool, from the selected developer directory or from any installed Xcode.
DEV_DIR=""
TOOL=$(xcrun --find appintentsmetadataprocessor 2>/dev/null || true)
if [ -z "$TOOL" ]; then
  for X in /Applications/Xcode*.app "$HOME"/Applications/Xcode*.app; do
    [ -d "$X/Contents/Developer" ] || continue
    T=$(DEVELOPER_DIR="$X/Contents/Developer" xcrun --find appintentsmetadataprocessor 2>/dev/null || true)
    if [ -n "$T" ]; then TOOL="$T"; DEV_DIR="$X/Contents/Developer"; break; fi
  done
fi
if [ -z "$TOOL" ]; then
  echo "  Siri actions skipped: appintentsmetadataprocessor comes with Xcode, which isn't installed."
  echo "  Install Xcode from the App Store, then rebuild. The app works the same without them."
  exit 0
fi
run_xcrun() { if [ -n "$DEV_DIR" ]; then DEVELOPER_DIR="$DEV_DIR" xcrun "$@"; else xcrun "$@"; fi; }

# What swift build recorded for the app module: its source list and the compiler's constant values.
CAP_CONFIG="$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}"
OBJ=$(find .build -maxdepth 7 -type d -path "*/$CAP_CONFIG/$MODULE-p.build/Objects-normal/*" 2>/dev/null | head -1)
if [ -z "$OBJ" ] || [ ! -f "$OBJ/$MODULE.SwiftFileList" ]; then
  echo "  Siri actions skipped: couldn't find the $CONFIG build of $MODULE under .build." >&2
  exit 0
fi
ARCH=$(basename "$OBJ")

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
find "$OBJ" -maxdepth 1 -name "*.swiftconstvalues" > "$WORK/constvalues.list"
: > "$WORK/metadata.list"
: > "$WORK/static-metadata.list"
if [ ! -s "$WORK/constvalues.list" ]; then
  echo "  Siri actions skipped: the build didn't record constant values for $MODULE." >&2
  exit 0
fi

TOOLCHAIN_DIR=$(cd "$(dirname "$TOOL")/../.." && pwd)
SDK=$(run_xcrun --sdk macosx --show-sdk-path)
XCODE_BUILD=$(run_xcrun xcodebuild -version 2>/dev/null | sed -n 's/Build version //p')

echo "→ Writing Siri and Shortcuts metadata"
run_xcrun appintentsmetadataprocessor \
  --toolchain-dir "$TOOLCHAIN_DIR" \
  --module-name "$MODULE" \
  --sdk-root "$SDK" \
  --xcode-version "${XCODE_BUILD:-unknown}" \
  --platform-family macOS \
  --deployment-target "$DEPLOYMENT_TARGET" \
  --bundle-identifier "$BUNDLE_ID" \
  --output "$APP/Contents/Resources" \
  --target-triple "$ARCH-apple-macos$DEPLOYMENT_TARGET" \
  --binary-file "$APP/Contents/MacOS/$MODULE" \
  --dependency-file "$WORK/$MODULE.d" \
  --stringsdata-file "$WORK/ExtractedAppShortcutsMetadata.stringsdata" \
  --source-file-list "$OBJ/$MODULE.SwiftFileList" \
  --metadata-file-list "$WORK/metadata.list" \
  --static-metadata-file-list "$WORK/static-metadata.list" \
  --swift-const-vals-list "$WORK/constvalues.list" \
  --compile-time-extraction \
  --deployment-aware-processing \
  --no-app-shortcuts-localization

if [ -d "$APP/Contents/Resources/Metadata.appintents" ]; then
  echo "✓ Siri actions added"
else
  echo "  The metadata tool ran but wrote no Metadata.appintents. Siri won't list AFM Studio's actions." >&2
fi
