#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP="AWDL Toggle.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/AWDLToggle"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.nickshtefan.awdl-toggle</string>
  <key>CFBundleName</key><string>AWDL Toggle</string>
  <key>CFBundleExecutable</key><string>AWDLToggle</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
codesign --force -s - "$APP"
echo "built: $APP"
