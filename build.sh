#!/bin/bash
# Build Repo Lines.app — a standalone macOS glass widget.
set -e
cd "$(dirname "$0")"

APP="RepoLines.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Repo Lines</string>
  <key>CFBundleDisplayName</key><string>Repo Lines</string>
  <key>CFBundleExecutable</key><string>RepoLines</string>
  <key>CFBundleIdentifier</key><string>com.local.repolines</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

cp logo.png "$APP/Contents/Resources/logo.png"

# app icon (Dock/Finder) from icon-src.png
if [ -f icon-src.png ]; then
  rm -rf icon.iconset; mkdir icon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s icon-src.png --out "icon.iconset/icon_${s}x${s}.png" >/dev/null
    d=$((s*2)); sips -z $d $d icon-src.png --out "icon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf icon.iconset
fi

echo "compiling…"
swiftc main.swift -O -framework Cocoa -o "$APP/Contents/MacOS/RepoLines"
# Stable self-signed identity so TCC (Screen Recording) permission persists across
# rebuilds instead of resetting every time (ad-hoc changes hash each build).
if security find-certificate -c "RepoLines Local Signing" >/dev/null 2>&1; then
  codesign --force --deep --sign "RepoLines Local Signing" "$APP" && echo "signed (stable identity)"
else
  echo "WARNING: 'RepoLines Local Signing' identity not found — app is unsigned/ad-hoc"
fi
echo "built $APP"
