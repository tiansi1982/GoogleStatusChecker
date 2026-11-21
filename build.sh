#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="GoogleStatusChecker"
APP_BUNDLE="${APP_NAME}.app"
BUILD_DIR=".build"
STAGED_BUNDLE="${BUILD_DIR}/${APP_BUNDLE}"
STAGED_CONTENTS="${STAGED_BUNDLE}/Contents"
STAGED_MACOS="${STAGED_CONTENTS}/MacOS"
STAGED_RESOURCES="${STAGED_CONTENTS}/Resources"

ARCHS="${ARCHS:-arm64}"
MIN_OS="${MIN_OS:-11.0}"

if [[ ! "$MIN_OS" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "!! 无效的 MIN_OS: $MIN_OS"
    exit 1
fi

if [[ ! -f AppIcon.icns ]]; then
    echo "!! 缺少 AppIcon.icns，请先运行 ./make-icon.sh"
    exit 1
fi

cleanup() {
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

rm -rf "$BUILD_DIR"
mkdir -p "$STAGED_MACOS" "$STAGED_RESOURCES" "$BUILD_DIR/ModuleCache"

echo "==> 编译 ${APP_NAME} (arch: ${ARCHS}, min macOS ${MIN_OS}) ..."
BINARIES=()
for arch in $ARCHS; do
    case "$arch" in
        arm64) triple="arm64-apple-macos${MIN_OS}" ;;
        x86_64) triple="x86_64-apple-macos${MIN_OS}" ;;
        *) echo "!! 不支持的架构: $arch"; exit 1 ;;
    esac

    binary="${BUILD_DIR}/${APP_NAME}.${arch}"
    echo "   - 编译 $arch ($triple)"
    xcrun swiftc \
        -O \
        -warnings-as-errors \
        -strict-concurrency=complete \
        -module-cache-path "$BUILD_DIR/ModuleCache" \
        -target "$triple" \
        -framework Cocoa \
        -o "$binary" \
        CheckerCore.swift AgentProbes.swift ExitIPHistory.swift IPReportWindow.swift main.swift
    BINARIES+=("$binary")
done

if [ "${#BINARIES[@]}" -gt 1 ]; then
    echo "   - 合并 universal binary"
    xcrun lipo -create -output "${STAGED_MACOS}/${APP_NAME}" "${BINARIES[@]}"
else
    cp "${BINARIES[0]}" "${STAGED_MACOS}/${APP_NAME}"
fi

cp Info.plist "${STAGED_CONTENTS}/Info.plist"
cp Resources/AgentEndpoints.json "$STAGED_RESOURCES/"
cp AppIcon.icns "${STAGED_RESOURCES}/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion ${MIN_OS}" "${STAGED_CONTENTS}/Info.plist"
plutil -lint "${STAGED_CONTENTS}/Info.plist" >/dev/null

echo "==> 代码签名 (adhoc) ..."
codesign --force --sign - "$STAGED_BUNDLE"
codesign --verify --deep --strict "$STAGED_BUNDLE"

# Replace the previous product only after compile, packaging, and signing succeed.
rm -rf "$APP_BUNDLE"
mv "$STAGED_BUNDLE" "$APP_BUNDLE"

echo ""
echo "==> 完成：$(pwd)/${APP_BUNDLE}"
echo -n "  架构: "
xcrun lipo -archs "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
echo "  最低系统: macOS ${MIN_OS}"
echo ""
echo "运行: open '${APP_BUNDLE}'"
echo "测试: ./test.sh"
