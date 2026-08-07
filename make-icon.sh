#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

ICONSET=".build/AppIcon.iconset"

rm -rf ".build"

echo "==> 渲染图标 PNG ..."
xcrun swift make_icon.swift "$ICONSET"

echo "==> 打包 AppIcon.icns ..."
iconutil -c icns "$ICONSET" -o AppIcon.icns

rm -rf ".build"

echo ""
echo "==> 完成：$(pwd)/AppIcon.icns"
echo "重新构建 app 以应用图标: ./build.sh"
