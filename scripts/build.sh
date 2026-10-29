#!/bin/bash
# Created by haodongsheng
set -euo pipefail
cd "$(dirname "$0")/.."
app="build/音频字幕.app"
mkdir -p "$app/Contents/MacOS"
swiftc -module-cache-path build/module-cache -target "$(uname -m)-apple-macosx14.2" -swift-version 5 -O -framework AppKit -framework CoreAudio -framework AVFoundation -framework Speech -framework CoreMedia Sources/main.swift -o "$app/Contents/MacOS/AudioCaptions"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --deep --sign - "$app"
echo "已生成 $app"
