#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="AgenticSidebar"
BUNDLE_ID="com.dogan.AgenticSidebar"
MIN_SYSTEM_VERSION="26.0"
APP_VERSION="0.1.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
swift build --product "$APP_NAME"
BUILD_BINARY="$(swift build --product "$APP_NAME" --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSRequiresAquaSystemAppearance</key>
  <false/>
</dict>
</plist>
PLIST

sign_app() {
  local identity="${AGENTIC_SIDEBAR_CODESIGN_IDENTITY:-}"

  if [[ -z "$identity" ]]; then
    identity="$(
      /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
        | awk -F '"' '/"Apple Development:/{print $2; exit}'
    )"
  fi

  if [[ -n "$identity" ]]; then
    echo "Signing $APP_NAME with Apple Development identity: $identity"
    /usr/bin/codesign \
      --force \
      --sign "$identity" \
      --identifier "$BUNDLE_ID" \
      --timestamp=none \
      "$APP_BUNDLE"
  else
    echo "warning: no Apple Development signing identity found; using ad-hoc signing. Keychain access may prompt after rebuilds." >&2
    /usr/bin/codesign \
      --force \
      --sign - \
      --identifier "$BUNDLE_ID" \
      --timestamp=none \
      "$APP_BUNDLE"
  fi

  /usr/bin/codesign --verify --strict "$APP_BUNDLE"
}

sign_app

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
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
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
