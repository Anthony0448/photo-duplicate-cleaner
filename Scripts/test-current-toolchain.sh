#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
developer_frameworks="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
developer_libraries="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
fallback_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"

cd "$project_dir"
CLANG_MODULE_CACHE_PATH="/tmp/photo-cleaner-module-cache" \
SDKROOT="$fallback_sdk" \
swift test \
    --disable-sandbox \
    --build-system native \
    --manifest-cache local \
    --cache-path /tmp/photo-cleaner-spm-cache \
    --config-path /tmp/photo-cleaner-spm-config \
    --security-path /tmp/photo-cleaner-spm-security \
    -Xswiftc -F \
    -Xswiftc "$developer_frameworks" \
    -Xlinker "-F$developer_frameworks" \
    -Xlinker -rpath \
    -Xlinker "$developer_frameworks" \
    -Xlinker -rpath \
    -Xlinker "$developer_libraries"
