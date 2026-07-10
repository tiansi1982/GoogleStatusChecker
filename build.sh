#!/bin/bash
#
# build.sh - 编译 main.swift 并打包成 GoogleStatusChecker.app
#
# 用法：
#   ./build.sh                          # 默认编译 arm64 (Apple Silicon) 并签名
#   ARCH="arm64 x86_64" ./build.sh      # 编译 universal (含 Intel)
#   MIN_OS=12.0 ./build.sh              # 调整最低支持系统版本
#
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="GoogleStatusChecker"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

# 默认只编 arm64 (Apple Silicon)；如需 universal 可 ARCH="arm64 x86_64" ./build.sh
ARCHS="${ARCHS:-arm64}"
MIN_OS="${MIN_OS:-11.0}"   # 最低支持 macOS 11 (Big Sur)

echo "==> 编译 ${APP_NAME} (arch: ${ARCHS}, min macOS ${MIN_OS}) ..."
# swiftc 不支持 -arch，需用 -target 三元组分别编译；多架构时用 lipo 合并
OBJ_LIST=""
for a in $ARCHS; do
    case "$a" in
        arm64)   triple="arm64-apple-macos${MIN_OS}" ;;
        x86_64)  triple="x86_64-apple-macos${MIN_OS}" ;;
        *) echo "!! 不支持的架构: $a"; exit 1 ;;
    esac
    echo "   - 编译 $a ($triple)"
    swiftc -O -target "$triple" -framework Cocoa \
        -o "${APP_NAME}.${a}" main.swift 2>&1
    OBJ_LIST="${OBJ_LIST} ${APP_NAME}.${a}"
done

# 单架构直接重命名；多架构用 lipo 合并成 universal
ARCH_COUNT=$(echo ${ARCHS} | wc -w | tr -d ' ')
if [ "${ARCH_COUNT}" -gt 1 ]; then
    echo "   - 合并 universal ..."
    lipo -create -output "${APP_NAME}" ${OBJ_LIST}
    rm -f ${OBJ_LIST}
else
    mv ${OBJ_LIST} "${APP_NAME}"
fi

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

echo "==> 代码签名 (adhoc) ..."
# 对整个 bundle 做临时签名（无需 Apple 开发者账号）。
# 注意：adhoc 签名在「别的 Mac」上仍会被 Gatekeeper 拦截，
# 需要在目标机上执行 xattr -cr 或右键->打开 一次。
codesign --force --sign - "${APP_BUNDLE}" 2>&1

echo ""
echo "==> 完成：$(pwd)/${APP_BUNDLE}"
echo ""
echo "产物信息："
echo -n "  架构: " ; lipo -archs "${MACOS_DIR}/${APP_NAME}"
codesign -dv "${APP_BUNDLE}" 2>&1 | sed -n 's/^[[:space:]]*Identifier=/  标识: /p; s/^[[:space:]]*Format=/  格式: /p; s/^[[:space:]]*Signature=/  签名: /p'
echo ""
echo "运行方式（本机）："
echo "    open '${APP_BUNDLE}'"
echo ""
echo "分发到其他 Mac："
echo "    1) 打包: zip -r -X GoogleStatusChecker.zip '${APP_BUNDLE}'"
echo "    2) 拷贝到目标 Mac 并解压"
echo "    3) 目标机终端执行: xattr -cr /path/to/GoogleStatusChecker.app"
echo "    4) 首次启动: 右键 -> 打开 (或 open '/path/to/GoogleStatusChecker.app')"
echo ""
echo "调试日志："
echo "    open '${APP_BUNDLE}' && log stream --predicate 'process == \"${APP_NAME}\"' --style compact"
