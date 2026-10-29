#!/bin/bash
# Created by haodongsheng
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -m)" != arm64 ]]; then echo "此构建脚本需要 Apple Silicon Mac" >&2; exit 1; fi
mkdir -p build/deps
scratch="$(mktemp -d "${TMPDIR:-/tmp}/videosubtitles.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
curl -fL --retry 3 https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-arm64.gz -o "$scratch/ffmpeg.gz"
echo "8923876afa8db5585022d7860ec7e589af192f441c56793971276d450ed3bbfa  $scratch/ffmpeg.gz" | shasum -a 256 -c -
curl -fL --retry 3 https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/darwin-arm64.LICENSE -o "$scratch/ffmpeg.license"
echo "cb48bf09a11f5fb576cddb0431c8f5ed0a60157a9ec942adffc13907cbe083f2  $scratch/ffmpeg.license" | shasum -a 256 -c -
gzip -dc "$scratch/ffmpeg.gz" > build/deps/ffmpeg
chmod +x build/deps/ffmpeg
cp "$scratch/ffmpeg.license" build/deps/FFmpeg.LICENSE
curl -fL --retry 3 https://codeload.github.com/ggml-org/whisper.cpp/tar.gz/refs/tags/v1.7.6 -o "$scratch/whisper.tar.gz"
tar -xzf "$scratch/whisper.tar.gz" -C "$scratch"
cmake -S "$scratch/whisper.cpp-1.7.6" -B "$scratch/whisper-build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF -DGGML_METAL=OFF -DGGML_OPENMP=OFF
cmake --build "$scratch/whisper-build" --target whisper-cli -j 4
cp "$scratch/whisper-build/bin/whisper-cli" build/deps/whisper-cli
cp "$scratch/whisper.cpp-1.7.6/LICENSE" build/deps/whisper.LICENSE
curl -fL --retry 3 https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin -o "$scratch/ggml-base.bin"
echo "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe  $scratch/ggml-base.bin" | shasum -a 256 -c -
cp "$scratch/ggml-base.bin" build/deps/ggml-base.bin
echo "依赖已准备，可运行 ./scripts/build-video.sh"
