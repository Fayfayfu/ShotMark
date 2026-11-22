#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

app_bundle="ShotMark.app"
mkdir -p "$app_bundle/Contents/MacOS"
cp .build/release/ShotMark "$app_bundle/Contents/MacOS/ShotMark"
cp Sources/ShotMark/Resources/Info.plist "$app_bundle/Contents/Info.plist"
codesign --force --sign - "$app_bundle"
