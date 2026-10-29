#!/bin/bash
# Created by haodongsheng
set -euo pipefail
cd "$(dirname "$0")/.."
app="build/视频翻译字幕.app"
deps="build/deps"
for tool in ffmpeg whisper-cli; do
  if [[ ! -x "$deps/$tool" ]]; then
    echo "缺少 Apple Silicon 依赖：$deps/$tool" >&2
    exit 1
  fi
  if ! lipo -archs "$deps/$tool" | grep -qw arm64; then
    echo "$deps/$tool 不支持 Apple Silicon" >&2
    exit 1
  fi
done
if [[ ! -f "$deps/ggml-base.bin" ]]; then echo "缺少多语言模型：$deps/ggml-base.bin" >&2; exit 1; fi
echo "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe  $deps/ggml-base.bin" | shasum -a 256 -c -
for license in FFmpeg.LICENSE whisper.LICENSE; do
  if [[ ! -f "$deps/$license" ]]; then echo "缺少许可证：$deps/$license" >&2; exit 1; fi
done
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build/module-cache
swiftc -module-cache-path build/module-cache -target arm64-apple-macosx15.0 -swift-version 5 -parse-as-library -O -framework SwiftUI -framework AVKit -framework AVFoundation -framework Speech -framework Translation VideoApp/SubtitleCache.swift VideoApp/AudioSilence.swift VideoApp/VideoSubtitles.swift -o "$app/Contents/MacOS/VideoSubtitles"
cp "$deps/ffmpeg" "$deps/whisper-cli" "$app/Contents/MacOS/"
cp VideoApp/Info.plist "$app/Contents/Info.plist"
cp "$deps/ggml-base.bin" "$app/Contents/Resources/ggml-base.bin"
for license in FFmpeg.LICENSE whisper.LICENSE; do
  cp "$deps/$license" "$app/Contents/Resources/$license"
done
codesign --force --sign - "$app/Contents/MacOS/ffmpeg"
codesign --force --sign - "$app/Contents/MacOS/whisper-cli"
codesign --force --sign - "$app"
echo "已生成 $app"
