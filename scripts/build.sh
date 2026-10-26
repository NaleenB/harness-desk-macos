#!/bin/zsh
# Build Harness Desk.app from Sources/main.swift.
#
# Usage:
#   ./scripts/build.sh            build build/HarnessDesk.app
#   ./scripts/build.sh --install  build and copy to $INSTALL_DIR (default /Applications)
#
# Override the identity with environment variables:
#   APP_NAME, BUNDLE_ID, VERSION, BUILD_NUMBER, INSTALL_DIR
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-HarnessDesk}"
DISPLAY_NAME="${DISPLAY_NAME:-Harness Desk}"
BUNDLE_ID="${BUNDLE_ID:-dev.naleen.harnessdesk}"
VERSION="${VERSION:-0.1.1}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
DO_INSTALL=0
[[ "${1:-}" == "--install" ]] && DO_INSTALL=1

command -v swiftc >/dev/null || {
  echo "swiftc not found. Install Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
}

mkdir -p "$BUILD_DIR"
echo "Compiling $APP_NAME…"
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -framework Cocoa -framework WebKit \
  -o "$BUILD_DIR/$APP_NAME" "$ROOT/Sources/main.swift"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

sed \
  -e "s|__APP_NAME__|$APP_NAME|g" \
  -e "s|__DISPLAY_NAME__|$DISPLAY_NAME|g" \
  -e "s|__EXECUTABLE__|$APP_NAME|g" \
  -e "s|__BUNDLE_ID__|$BUNDLE_ID|g" \
  -e "s|__VERSION__|$VERSION|g" \
  -e "s|__BUILD__|$BUILD_NUMBER|g" \
  "$ROOT/Resources/Info.plist.in" > "$APP/Contents/Info.plist"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
  plutil -remove CFBundleIconFile "$APP/Contents/Info.plist" 2>/dev/null || true
fi

codesign --force --sign - "$APP" >/dev/null
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "Built: $APP"
if (( DO_INSTALL )); then
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALL_DIR/$APP_NAME.app"
  cp -R "$APP" "$INSTALL_DIR/"
  echo "Installed: $INSTALL_DIR/$APP_NAME.app"
fi
