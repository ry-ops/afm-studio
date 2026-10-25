#!/usr/bin/env bash
# Builds "AFM Studio.app" (with the afm CLI inside) into ./build.
#   bash scripts/build-app.sh            build only
#   bash scripts/build-app.sh --install  also install it in /Applications and link the afm command
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
APP="build/AFM Studio.app"
VERSION=$(sed -n 's/.*string = "\(.*\)".*/\1/p' Sources/AFMKit/Version.swift)

echo "→ Building ($CONFIG)…"
swift build -c "$CONFIG" --product afm
swift build -c "$CONFIG" --product AFMStudio
BIN=$(swift build -c "$CONFIG" --show-bin-path)

echo "→ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/AFMStudio" "$APP/Contents/MacOS/AFMStudio"
cp "$BIN/afm" "$APP/Contents/Helpers/afm"

if [ ! -f build/AppIcon.icns ]; then
  echo "→ Drawing icon"
  swift scripts/make-icon.swift build/AppIcon.iconset >/dev/null
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AFM Studio</string>
  <key>CFBundleDisplayName</key><string>AFM Studio</string>
  <key>CFBundleIdentifier</key><string>dev.ry-ops.afm-studio</string>
  <key>CFBundleExecutable</key><string>AFMStudio</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

echo "→ Signing (ad hoc)"
codesign --force --sign - "$APP/Contents/Helpers/afm"
codesign --force --sign - "$APP"

echo "✓ Built $APP ($VERSION)"

if [ "${1:-}" = "--install" ]; then
  DEST="/Applications"
  [ -w "$DEST" ] || DEST="$HOME/Applications"   # no write access to /Applications: install for this user only
  mkdir -p "$DEST"
  osascript -e 'tell application "AFM Studio" to quit' >/dev/null 2>&1 || true
  rm -rf "$DEST/AFM Studio.app"
  cp -R "$APP" "$DEST/"
  echo "✓ Installed to $DEST/AFM Studio.app"

  # An older copy in ~/Applications goes to the Trash, so Spotlight and Launchpad show only one.
  OLD="$HOME/Applications/AFM Studio.app"
  if [ "$DEST" != "$HOME/Applications" ] && [ -d "$OLD" ]; then
    osascript -e "tell application \"Finder\" to delete POSIX file \"$OLD\"" >/dev/null 2>&1 || rm -rf "$OLD"
    echo "✓ Moved the old copy in ~/Applications to the Trash"
  fi

  # Point the afm command at the installed app (the app also does this when it opens).
  BIN_DIR="${AFM_INSTALL_DIR:-$HOME/.local/bin}"
  mkdir -p "$BIN_DIR"
  ln -sf "$DEST/AFM Studio.app/Contents/Helpers/afm" "$BIN_DIR/afm"
  echo "✓ Linked $BIN_DIR/afm"
  case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "  Add $BIN_DIR to your PATH to run afm from anywhere." ;; esac
fi
