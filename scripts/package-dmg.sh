#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
version="0.0.6"
build_number="6"
sparkle_account="studio.lumen.oss"
derived_dir="$repo_dir/.build/release-v006"
app_path="$derived_dir/Build/Products/Release/Lumen.app"
dist_dir="$repo_dir/dist"
output_path="$dist_dir/Lumen-$version.dmg"
appcast_path="$dist_dir/appcast.xml"
tracked_appcast_path="$repo_dir/appcast.xml"

if [[ -e "$output_path" ]]; then
    print -u2 "Refusing to overwrite existing artifact: $output_path"
    exit 2
fi

stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/lumen-v006-dmg.XXXXXX")"
temp_dmg="$stage_dir/Lumen-$version.dmg"
mount_dir="$stage_dir/mount"
appcast_dir="$stage_dir/appcast"
mounted=0
cleanup() {
    if [[ "$mounted" == "1" ]]; then
        hdiutil detach "$mount_dir" -quiet || true
    fi
    if [[ "$stage_dir" == "${TMPDIR:-/tmp}"/lumen-v006-dmg.* ]]; then
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
    -onlyUsePackageVersionsFromResolvedFile \
    -skipPackageUpdates \
    -packageAuthorizationProvider netrc \
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

signed_entitlements="$(codesign -d --entitlements :- "$app_path" 2>/dev/null || true)"
[[ -z "$signed_entitlements" ]]
if plutil -extract SUEnableInstallerLauncherService raw "$app_path/Contents/Info.plist" >/dev/null 2>&1; then
    print -u2 "Non-sandboxed builds must use Sparkle's in-process installer launcher"
    exit 3
fi

root_team="$(codesign -dv "$app_path" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
sparkle_team="$(codesign -dv "$app_path/Contents/Frameworks/Sparkle.framework" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ "$root_team" == "$sparkle_team" ]]
[[ "$root_team" == "not set" ]]
if codesign -dv "$app_path" 2>&1 | grep -q 'flags=.*runtime'; then
    print -u2 "This distribution profile must not enable hardened runtime without a matching identity"
    exit 4
fi

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
    print -u2 "Unexpected assessment result for the current distribution profile"
    exit 3
else
    print "System assessment matched the current distribution profile"
fi

hdiutil detach "$mount_dir" -quiet
mounted=0

sparkle_dir="$derived_dir/SourcePackages/artifacts/sparkle/Sparkle"
generate_appcast="$sparkle_dir/bin/generate_appcast"
generate_keys="$sparkle_dir/bin/generate_keys"
sign_update="$sparkle_dir/bin/sign_update"
[[ -x "$generate_appcast" ]]
[[ -x "$generate_keys" ]]
[[ -x "$sign_update" ]]

expected_public_key="$(plutil -extract SUPublicEDKey raw "$app_path/Contents/Info.plist")"
signing_public_key="$("$generate_keys" --account "$sparkle_account" -p)"
[[ "$signing_public_key" == "$expected_public_key" ]]

private_key_path="$stage_dir/sparkle-signing.key"
"$generate_keys" --account "$sparkle_account" -x "$private_key_path"
chmod 600 "$private_key_path"

mkdir -p "$appcast_dir"
ditto "$output_path" "$appcast_dir/Lumen-$version.dmg"
ditto "$repo_dir/docs/releases/v$version.md" "$appcast_dir/Lumen-$version.md"
if [[ -f "$tracked_appcast_path" ]]; then
    ditto "$tracked_appcast_path" "$appcast_dir/appcast.xml"
fi

"$generate_appcast" \
    --ed-key-file "$private_key_path" \
    --download-url-prefix "https://github.com/ihopefulChina/Lumen/releases/download/v$version/" \
    --link "https://github.com/ihopefulChina/Lumen/releases/tag/v$version" \
    --embed-release-notes \
    --maximum-deltas 0 \
    "$appcast_dir"

signature="$(xmllint --xpath "string(//*[local-name()='item' and *[local-name()='version' and text()='$build_number']]/*[local-name()='enclosure']/@*[local-name()='edSignature'])" "$appcast_dir/appcast.xml")"
declared_length="$(xmllint --xpath "string(//*[local-name()='item' and *[local-name()='version' and text()='$build_number']]/*[local-name()='enclosure']/@length)" "$appcast_dir/appcast.xml")"
[[ -n "$signature" ]]
[[ "$declared_length" == "$(stat -f %z "$output_path")" ]]
"$sign_update" --verify --ed-key-file "$private_key_path" "$output_path" "$signature"
unlink "$private_key_path"
ditto "$appcast_dir/appcast.xml" "$appcast_path"
ditto "$appcast_dir/appcast.xml" "$tracked_appcast_path"

shasum -a 256 "$output_path"
shasum -a 256 "$appcast_path"
