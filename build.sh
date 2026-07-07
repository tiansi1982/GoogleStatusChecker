#!/bin/bash
#
# build.sh - 编译 main.swift 并打包成 GoogleStatusChecker.app
#
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="GoogleStatusChecker"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "==> 编译 ${APP_NAME} ..."
swiftc \
    -O \
    -framework Cocoa \
    -o "${APP_NAME}" \
    main.swift 2>&1

if [ ! -f "${APP_NAME}" ]; then
    echo "!! 编译失败"
    exit 1
fi

echo "==> 打包 .app ..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"
cp Info.plist "${CONTENTS_DIR}/Info.plist"

# 移除中间可执行文件（已复制进 bundle）
rm -f "${APP_NAME}"

echo "==> 完成：$(pwd)/${APP_BUNDLE}"
echo ""
echo "运行方式："
echo "    open '${APP_BUNDLE}'"
echo ""
echo "查看日志（调试）："
echo "    open '${APP_BUNDLE}' && log stream --predicate 'process == \"${APP_NAME}\"' --style compact"
