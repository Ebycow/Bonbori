#!/bin/zsh
# SPDX-License-Identifier: GPL-2.0-or-later
# Builds Bonbori.app (release) next to this script.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product Bonbori 2>&1 | grep -vE "search path .* not found|built for newer version" || true
BIN=$(swift build -c release --show-bin-path)/Bonbori

APP=Bonbori.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Bonbori"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Bonbori</string>
    <key>CFBundleDisplayName</key><string>Bonbori</string>
    <key>CFBundleIdentifier</key><string>net.ebycow.bonbori</string>
    <key>CFBundleExecutable</key><string>Bonbori</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>BonDriverProxyEx サーバーに接続してテレビ放送を受信します。</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>翻訳字幕のために、放送の音声をこの Mac 上で文字に起こします。</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "built $(pwd)/$APP"
