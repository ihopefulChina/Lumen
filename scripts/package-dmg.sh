#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
version="0.0.3"
build_number="3"
derived_dir="$repo_dir/.build/release-v003"
app_path="$derived_dir/Build/Products/Release/Lumen.app"
dist_dir="$repo_dir/dist"
output_path="$dist_dir/Lumen-$version.dmg"

if [[ -e "$output_path" ]]; then
    print -u2 "Refusing to overwrite existing artifact: $output_path"
    exit 2
fi

stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/lumen-v003-dmg.XXXXXX")"
temp_dmg="$stage_dir/Lumen-$version.dmg"
mount_dir="$stage_dir/mount"
mounted=0
cleanup() {
    if [[ "$mounted" == "1" ]]; then
        hdiutil detach "$mount_dir" -quiet || true
    fi
    if [[ "$stage_dir" == "${TMPDIR:-/tmp}"/lumen-v003-dmg.* ]]; then
        rm -rf "$stage_dir"
    fi
}
trap cleanup EXIT

cd "$repo_dir"
xcodebuild \
    -project Lumen.xcodeproj \
    -scheme Lumen \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_dir" \
    clean build \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM=

actual_version="$(plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")"
actual_build="$(plutil -extract CFBundleVersion raw "$app_path/Contents/Info.plist")"
[[ "$actual_version" == "$version" ]]
[[ "$actual_build" == "$build_number" ]]

codesign --force --deep --sign - "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

mkdir -p "$stage_dir/volume" "$dist_dir"
ditto "$app_path" "$stage_dir/volume/Lumen.app"
ln -s /Applications "$stage_dir/volume/Applications"

hdiutil create \
    -volname "Lumen $version" \
    -srcfolder "$stage_dir/volume" \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$temp_dmg"

mv "$temp_dmg" "$output_path"
hdiutil verify "$output_path"
mkdir -p "$mount_dir"
hdiutil attach "$output_path" -readonly -nobrowse -mountpoint "$mount_dir"
mounted=1

mounted_version="$(plutil -extract CFBundleShortVersionString raw "$mount_dir/Lumen.app/Contents/Info.plist")"
mounted_build="$(plutil -extract CFBundleVersion raw "$mount_dir/Lumen.app/Contents/Info.plist")"
[[ "$mounted_version" == "$version" ]]
[[ "$mounted_build" == "$build_number" ]]
codesign --verify --deep --strict --verbose=2 "$mount_dir/Lumen.app"
if spctl --assess --type execute --verbose=2 "$mount_dir/Lumen.app" > "$stage_dir/spctl.log" 2>&1; then
    print -u2 "Expected the ad-hoc, non-notarized app to be rejected by Gatekeeper"
    exit 3
else
    print "Gatekeeper result: rejected as expected for an ad-hoc, non-notarized build"
fi

hdiutil detach "$mount_dir" -quiet
mounted=0
shasum -a 256 "$output_path"
