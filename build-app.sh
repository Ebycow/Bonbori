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
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 放送字幕の内蔵音: the recordings have terms of their own, so they stay out of this repository.
ROM=${TVCAPTIONMOD2:-../TVCaptionMod2}/src/rom
if [[ -f "$ROM/readme.txt" ]]; then
    mkdir "$APP/Contents/Resources/CaptionSounds"
    cp "$ROM"/*.wav "$ROM/readme.txt" "$APP/Contents/Resources/CaptionSounds/"
else
    echo "$ROM not found: 放送字幕の内蔵音はシステムサウンドになります"
fi

# データ放送: web-bml and the page around it, built with npm.
WEB=Web/DataBroadcasting
if command -v npm >/dev/null; then
    [[ "$WEB/node_modules/.package-lock.json" -nt "$WEB/package-lock.json" ]] ||
        (cd "$WEB" && npm ci --ignore-scripts --no-audit --no-fund --silent)
    (cd "$WEB" && npm run build --silent >/dev/null)
    mkdir "$APP/Contents/Resources/DataBroadcasting"
    cp "$WEB/index.html" "$WEB/dist/main.js" "$WEB/dist/main.js.LICENSE.txt" "$WEB/LICENSE.TVTDataBroadcastingWV2" \
        "$WEB"/node_modules/web-bml-fonts/*.woff2 "$APP/Contents/Resources/DataBroadcasting/"
    cp "$WEB/node_modules/web-bml/LICENSE" "$APP/Contents/Resources/DataBroadcasting/LICENSE.web-bml"
    cp "$WEB/node_modules/web-bml-fonts/LICENSE.txt" "$APP/Contents/Resources/DataBroadcasting/LICENSE.fonts"
else
    echo "npm not found: データ放送はこのビルドでは使えません"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Bonbori</string>
    <key>CFBundleDisplayName</key><string>Bonbori</string>
    <key>CFBundleIdentifier</key><string>net.ebycow.bonbori</string>
    <key>CFBundleExecutable</key><string>Bonbori</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- データ放送の通信コンテンツには http のものがある。ページ自体は通信できない -->
    <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
    <key>NSLocalNetworkUsageDescription</key><string>BonDriverProxyEx サーバーに接続してテレビ放送を受信します。</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>翻訳字幕のために、放送の音声をこの Mac 上で文字に起こします。</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "built $(pwd)/$APP"
