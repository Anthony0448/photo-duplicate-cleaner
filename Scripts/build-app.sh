#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
configuration="${1:-release}"
if (( $# > 0 )); then
    shift
fi
build_args=("$@")

cd "$project_dir"
if [[ -n "${SDKROOT:-}" && -f "$SDKROOT/SDKSettings.plist" ]]; then
    sdk_version="$(plutil -extract Version raw "$SDKROOT/SDKSettings.plist")"
else
    sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
fi
sdk_major="${sdk_version%%.*}"
swift_args=()

if [[ "$sdk_major" == <-> ]] && (( sdk_major >= 27 )); then
    swift_args=(-Xswiftc -DPHOTO_EXTENDED_METADATA)
else
    echo "Building with macOS SDK $sdk_version; macOS 27-only metadata fields are disabled." >&2
fi

swift build -c "$configuration" "${swift_args[@]}" "${build_args[@]}"
bin_dir="$(swift build -c "$configuration" "${swift_args[@]}" "${build_args[@]}" --show-bin-path)"
app_dir="$project_dir/dist/Photo Duplicate Cleaner.app"
contents_dir="$app_dir/Contents"

rm -rf "$app_dir"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$bin_dir/PhotoDuplicateCleaner" "$contents_dir/MacOS/PhotoDuplicateCleaner"
cp "$project_dir/Resources/AppInfo.plist" "$contents_dir/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"
codesign --force --sign - --timestamp=none "$app_dir"

echo "$app_dir"
