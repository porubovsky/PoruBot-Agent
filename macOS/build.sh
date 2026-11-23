#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
destination="${1:-"$here/build"}"
mkdir -p "$destination"
destination="$(cd "$destination" && pwd)"
app="$destination/PoruBot.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$here/Info.plist" "$app/Contents/Info.plist"
cp "$here/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
target="$(uname -m)-apple-macos13.0"
swiftc -swift-version 5 -enable-bare-slash-regex -target "$target" -parse-as-library \
  "$here/AgentDesk.swift" "$here/Providers.swift" -o "$app/Contents/MacOS/PoruBot"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
