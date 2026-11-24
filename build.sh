#!/bin/sh
set -eu
cd "$(dirname "$0")"
bundle="${1:?Pass the destination .app path}"
mkdir -p "$bundle/Contents/MacOS"
cp Info.plist "$bundle/Contents/Info.plist"
xcrun clang -arch arm64 -arch x86_64 -fobjc-arc -O2 -Wall -mmacosx-version-min=14.4 App.m Audio.m -framework AppKit -framework ApplicationServices -framework CoreAudio -o "$bundle/Contents/MacOS/DisplaySound"
codesign -f --options runtime -s "${SIGN_IDENTITY:--}" "$bundle"
