#!/bin/bash
# Build and install DictionaryHistory.
# Produces a universal (arm64 + x86_64) menu-bar app, registers its Service,
# and starts it at login. Re-run any time to upgrade in place.
set -euo pipefail

APP_NAME="DictionaryHistory"
DEST="${DEST:-$HOME/Applications}"
APP="$DEST/$APP_NAME.app"
LABEL="com.edm.dictionaryhistory"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
BUILD="$(mktemp -d)"; trap 'rm -rf "$BUILD"' EXIT

command -v swiftc >/dev/null || { echo "error: swiftc missing. Run: xcode-select --install"; exit 1; }

echo "==> Building universal binary"
SLICES=()
for arch in arm64 x86_64; do
  if swiftc -target "$arch-apple-macos12.0" -framework Cocoa -framework SwiftUI -lsqlite3 \
       Sources/*.swift -o "$BUILD/$arch" 2>"$BUILD/$arch.err"; then
    echo "    $arch ok"; SLICES+=("$BUILD/$arch")
  else
    echo "    $arch skipped:"; sed 's/^/      /' "$BUILD/$arch.err" | tail -6
  fi
done
[ ${#SLICES[@]} -gt 0 ] || { echo "error: no architecture built"; exit 1; }
lipo -create "${SLICES[@]}" -output "$BUILD/$APP_NAME"
echo "    -> $(lipo -archs "$BUILD/$APP_NAME")"

echo "==> Assembling bundle"
# Stop a running copy so the binary can be replaced.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
pkill -x "$APP_NAME" 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BUILD/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# Regenerate the icon if the generator is newer than the built .icns.
if [ tools/makeicon.swift -nt Resources/AppIcon.icns ] 2>/dev/null; then
  echo "    regenerating icon"
  swift tools/makeicon.swift >/dev/null 2>&1 && \
    iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns 2>/dev/null || true
fi
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>Dictionary History</string>
    <key>CFBundleIdentifier</key><string>$LABEL</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Local only. No network access.</string>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict><key>default</key><string>Look Up &amp; Log</string></dict>
            <key>NSMessage</key><string>lookUpAndLog</string>
            <key>NSPortName</key><string>$APP_NAME</string>
            <key>NSSendTypes</key>
            <array><string>NSStringPboardType</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc signature: required for the binary to launch at all on Apple Silicon.
codesign --force --sign - "$APP" 2>/dev/null || echo "    (codesign skipped)"

echo "==> Registering Service"
/System/Library/CoreServices/pbs -flush 2>/dev/null || true
touch "$APP"
# Finder and the Dock cache icons aggressively; force a re-read.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
  -f "$APP" 2>/dev/null || true

echo "==> Installing login agent"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$APP/Contents/MacOS/$APP_NAME</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
</dict>
</plist>
PLIST
launchctl bootstrap "gui/$UID" "$AGENT" 2>/dev/null || launchctl load "$AGENT" 2>/dev/null || true

echo "==> Installing 'dh' command"
for d in /usr/local/bin "$HOME/.local/bin"; do
  if mkdir -p "$d" 2>/dev/null && [ -w "$d" ]; then
    ln -sf "$APP/Contents/MacOS/$APP_NAME" "$d/dh"; echo "    $d/dh"; DHBIN="$d"; break
  fi
done
[ -n "${DHBIN:-}" ] || echo "    (no writable bin dir; call the binary directly)"

cat <<DONE

  Installed: $APP
  History:   ~/Library/Application Support/DictionaryHistory/history.db

  ONE manual step - grant Accessibility, so the app can see Dictionary.app:
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
  and tick DictionaryHistory.

  Then open Dictionary from the Dock and look words up as usual.

  NOTE: rebuilding changes this app's ad-hoc signature, so macOS silently revokes
  that grant every time. Re-tick it after each install; the menu warns when needed.

  Try it now:   dh add serendipity && dh recent

DONE
