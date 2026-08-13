#!/bin/bash
# Build, install Repo Lines to ~/Applications, and set it to launch at login.
set -e
cd "$(dirname "$0")"

./build.sh

DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/RepoLines.app"
cp -R RepoLines.app "$DEST/RepoLines.app"
echo "installed → $DEST/RepoLines.app"

# Launch at login via a user LaunchAgent (RunAtLoad, no KeepAlive so ✕ stays quit)
PLIST="$HOME/Library/LaunchAgents/com.local.repolines.plist"
BIN="$DEST/RepoLines.app/Contents/MacOS/RepoLines"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.local.repolines</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
rm -rf RepoLines.app
echo "launch-at-login installed and started"
