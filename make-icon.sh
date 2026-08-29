#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

ICONSET=".build/AppIcon.iconset"
ICON_RENDERER=".build/make_icon"
MODULE_CACHE=".build/ModuleCache"

rm -rf ".build"
mkdir -p "$MODULE_CACHE"

echo "==> 渲染图标 PNG ..."
xcrun swiftc \
    -module-cache-path "$MODULE_CACHE" \
    -target arm64-apple-macos11.0 \
    -framework Cocoa \
    -o "$ICON_RENDERER" \
    make_icon.swift
"$ICON_RENDERER" "$ICONSET" "AppIcon.icns"

rm -rf ".build"

echo ""
echo "==> 完成：$(pwd)/AppIcon.icns"
echo "重新构建 app 以应用图标: ./build.sh"
