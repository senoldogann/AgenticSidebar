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
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

# SIGTERM is handled by the app, which stops its OpenCode server and the MCP
# servers that server started. That cleanup is asynchronous, so wait for it
# instead of racing the new instance against the old one's teardown — a race
# here is what used to leave a server (and its whole process tree) orphaned on
# every rebuild.
#
# LaunchServices ile başlayan örneğin süreç adı tam yoldur (`ps` çıktısı
# `/Applications/Ag…`), o yüzden `-x AgenticSidebar` onu hiç yakalayamaz ve
# eski build yaşarken `LSMultipleInstancesProhibited` yenisini açtırmaz.
# Yürütülebilir yol eşleştirilir; `[r]` deseni komutu çalıştıran kabuğun
# kendisini eşlemekten korur.
APP_PROCESS_PATTERN="AgenticSidebar\\.app/Contents/MacOS/AgenticSideba[r]"
pkill -f "$APP_PROCESS_PATTERN" >/dev/null 2>&1 || true
for _ in $(seq 1 40); do
  pgrep -f "$APP_PROCESS_PATTERN" >/dev/null 2>&1 || break
  sleep 0.25
done

if pgrep -f "$APP_PROCESS_PATTERN" >/dev/null 2>&1; then
  echo "warning: $APP_NAME did not exit after SIGTERM; it may leave its OpenCode server behind." >&2
fi

cd "$ROOT_DIR"
swift build --product "$APP_NAME" -Xswiftc -warnings-as-errors
BUILD_BINARY="$(swift build --product "$APP_NAME" --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
mkdir -p "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
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
  <key>LSMultipleInstancesProhibited</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSRequiresAquaSystemAppearance</key>
  <false/>
  <key>NSMicrophoneUsageDescription</key>
  <string>AgenticSidebar uses the microphone only when you tap the dictation button, to transcribe your speech into the composer draft.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>AgenticSidebar uses speech recognition only when you tap the dictation button, to transcribe your speech into the composer draft.</string>
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

install_to_applications() {
  local target_app="/Applications/$APP_NAME.app"
  echo "Installing $APP_NAME to /Applications..."
  rm -rf "$target_app"
  cp -R "$APP_BUNDLE" "$target_app"
  xattr -cr "$target_app" 2>/dev/null || true
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target_app" 2>/dev/null || true
  touch "$target_app"
  echo "Installed $APP_NAME.app to /Applications successfully."
}

open_app() {
  install_to_applications
  /usr/bin/open "/Applications/$APP_NAME.app"
}

case "$MODE" in
  run|install)
    open_app
    ;;
  build|--build)
    # Derle, paketle, imzala; kurma ve açma. `/Applications` yazılamadığı
    # makinelerde ve yalnızca derleme doğrulamasında kullanılır.
    echo "Built $APP_BUNDLE without installing."
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
    # Açılış + pencere + sunucu ayağa kalkması 1 sn'yi aşabilir; sabit uyku
    # yerine süre dolumlu yoklama yanlış negatifi önler.
    for _ in $(seq 1 40); do
      pgrep -f "$APP_PROCESS_PATTERN" >/dev/null 2>&1 && break
      sleep 0.25
    done
    pgrep -f "$APP_PROCESS_PATTERN" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|build|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
