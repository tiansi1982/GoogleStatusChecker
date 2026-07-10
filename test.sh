#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

BUILD_DIR=".build-tests"
trap 'rm -rf "$BUILD_DIR"' EXIT

mkdir -p "$BUILD_DIR/ModuleCache"

xcrun swiftc \
    -warnings-as-errors \
    -strict-concurrency=complete \
    -module-cache-path "$BUILD_DIR/ModuleCache" \
    -o "$BUILD_DIR/CheckerCoreTests" \
    CheckerCore.swift Tests/CheckerCoreTests.swift

"$BUILD_DIR/CheckerCoreTests"
