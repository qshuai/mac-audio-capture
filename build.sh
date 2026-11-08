#!/bin/bash
# 构建 sysaudio：命令行程序 + 可独立授权的 .app 包
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
DIST="$DIR/dist"
APP="$DIST/SysAudioCapture.app"
MACOS="$APP/Contents/MacOS"

mkdir -p "$MACOS"

echo "编译 main.m ..."
clang -fobjc-arc -fblocks -O2 -Wall -Wno-deprecated-declarations \
      -mmacosx-version-min=13.0 \
      -framework Foundation \
      -framework ScreenCaptureKit \
      -framework CoreMedia \
      -framework CoreVideo \
      -framework ApplicationServices \
      -o "$DIST/sysaudio" "$DIR/main.m"

cp "$DIST/sysaudio" "$MACOS/sysaudio"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - --identifier com.workbuddy.sysaudio "$APP" >/dev/null 2>&1

echo ""
echo "构建完成："
echo "  命令行程序 : $DIST/sysaudio"
echo "  独立 App   : $APP"
echo ""
echo "先检查权限：$DIST/sysaudio --check"
echo "开始录制  ：$DIST/sysaudio -t 30 -o ~/Desktop/test.wav"
