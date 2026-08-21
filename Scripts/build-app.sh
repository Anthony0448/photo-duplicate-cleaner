#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
configuration="${1:-release}"

cd "$project_dir"
extended_metadata=1
if ! swift build -c "$configuration" -Xswiftc -DPHOTO_EXTENDED_METADATA; then
    fallback_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    if [[ ! -d "$fallback_sdk" ]]; then
        echo "The active Swift compiler and SDK do not match, and no compatible fallback SDK was found." >&2
        exit 1
    fi
    echo "Active macOS 27 toolchain is mismatched; building with the compatible 26.5 SDK." >&2
    echo "Caption, keyword, rating, and macOS 27 resource fields will be disabled in this build." >&2
    extended_metadata=0
    fallback_args=(
        --disable-sandbox
        --build-system native
        --manifest-cache local
        --cache-path /tmp/photo-cleaner-spm-cache
        --config-path /tmp/photo-cleaner-spm-config
        --security-path /tmp/photo-cleaner-spm-security
    )
    CLANG_MODULE_CACHE_PATH=/tmp/photo-cleaner-module-cache \
    SDKROOT="$fallback_sdk" \
    swift build "${fallback_args[@]}" -c "$configuration"
fi

if [[ "$extended_metadata" == 1 ]]; then
    bin_dir="$(swift build -c "$configuration" -Xswiftc -DPHOTO_EXTENDED_METADATA --show-bin-path)"
else
    bin_dir="$(CLANG_MODULE_CACHE_PATH=/tmp/photo-cleaner-module-cache SDKROOT="$fallback_sdk" swift build "${fallback_args[@]}" -c "$configuration" --show-bin-path)"
fi
app_dir="$project_dir/dist/Photo Duplicate Cleaner.app"
contents_dir="$app_dir/Contents"

rm -rf "$app_dir"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$bin_dir/PhotoDuplicateCleaner" "$contents_dir/MacOS/PhotoDuplicateCleaner"
cp "$project_dir/Resources/AppInfo.plist" "$contents_dir/Info.plist"
codesign --force --sign - --timestamp=none "$app_dir"

echo "$app_dir"
