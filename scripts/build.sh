#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
swift build -c release
app="$PWD/dist/BuddyCam.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Fonts"
cp .build/release/PhoneRecorder "$app/Contents/MacOS/PhoneRecorder"
cp Assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Assets/Fonts/*.ttf "$app/Contents/Resources/Fonts/"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign "${PHONE_RECORDER_SIGNING_IDENTITY:-Developer ID Application: Francesco Oddo (G2442WAF29)}" "$app"
codesign --verify --strict "$app"
print -r -- "$app"
