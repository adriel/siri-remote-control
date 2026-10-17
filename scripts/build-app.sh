#!/usr/bin/env bash
# Builds "Remote Control.app" into ./build and signs it.
#
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  build, copy to /Applications, and launch
#   scripts/build-app.sh --run      build and launch from ./build
#
# Signing: uses the first "Apple Development" or "Developer ID Application" identity in your keychain
# (Xcode → Settings → Accounts → add your Apple ID to get one for free). Override with CODESIGN_IDENTITY.
# Without one the app is ad-hoc signed and macOS asks for Accessibility/Input Monitoring again after every build.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Remote Control"
EXECUTABLE="RemoteControl"
CONFIG="${CONFIG:-release}"
APP="build/${APP_NAME}.app"

swift build -c "$CONFIG" --product "$EXECUTABLE"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ ! -f build/AppIcon.icns || scripts/make-icon.swift -nt build/AppIcon.icns ]]; then
  swift scripts/make-icon.swift build >/dev/null
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"
  echo "warning: no signing identity found; ad-hoc signing. Permissions will need re-granting after each build." >&2
fi
codesign --force --sign "$IDENTITY" --identifier com.runaroundhome.RemoteControl "$APP"
echo "Built $APP (signed with: $IDENTITY)"

# Quit a running copy and wait for it to exit; launching while it's still quitting fails with error -600.
quit_running() {
  pkill -x "$EXECUTABLE" 2>/dev/null || return 0
  for _ in $(seq 1 50); do pgrep -x "$EXECUTABLE" >/dev/null || return 0; sleep 0.1; done
}

case "${1:-}" in
  --install)
    quit_running
    rm -rf "/Applications/${APP_NAME}.app"
    ditto "$APP" "/Applications/${APP_NAME}.app"
    open "/Applications/${APP_NAME}.app"
    echo "Installed to /Applications/${APP_NAME}.app"
    ;;
  --run)
    quit_running
    open "$APP"
    ;;
esac
