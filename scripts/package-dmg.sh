#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
mode="${1:-}"
version="0.0.7"
build_number="7"
sparkle_account="studio.lumen.oss"
derived_dir="$repo_dir/.build/release-v007-$mode"
app_path="$derived_dir/Build/Products/Release/Lumen.app"
dist_dir="$repo_dir/dist"
tracked_appcast_path="$repo_dir/appcast.xml"

usage() {
    print -u2 "Usage: scripts/package-dmg.sh <development|release>"
    exit 64
}

fail() {
    print -u2 "Packaging failed: $1"
    exit 1
}

[[ "$mode" == "development" || "$mode" == "release" ]] || usage

if [[ "$mode" == "development" ]]; then
    artifact_name="Lumen-$version-development.dmg"
else
    artifact_name="Lumen-$version.dmg"
fi
output_path="$dist_dir/$artifact_name"
[[ ! -e "$output_path" ]] || fail "refusing to overwrite $output_path"

developer_identity="${LUMEN_DEVELOPER_ID_APPLICATION:-}"
development_team="${LUMEN_DEVELOPMENT_TEAM:-}"
notary_profile="${LUMEN_NOTARY_PROFILE:-}"

# Release requirements are checked before the build or any tracked file changes.
if [[ "$mode" == "release" ]]; then
    [[ -n "$developer_identity" ]] || fail "LUMEN_DEVELOPER_ID_APPLICATION is required"
    [[ -n "$development_team" ]] || fail "LUMEN_DEVELOPMENT_TEAM is required"
    [[ -n "$notary_profile" ]] || fail "LUMEN_NOTARY_PROFILE is required"
    security find-identity -v -p codesigning | grep -Fq "\"$developer_identity\"" \
        || fail "the configured Developer ID Application identity is unavailable"
    xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null \
        || fail "the configured notarization profile is unavailable"
fi

stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/lumen-v007-dmg.XXXXXX")"
temp_dmg="$stage_dir/$artifact_name"
appcast_dir="$stage_dir/appcast"
private_key_path="$stage_dir/sparkle-signing.key"
cleanup() {
    if [[ "$stage_dir" == "${TMPDIR:-/tmp}"/lumen-v007-dmg.* ]]; then
        rm -rf "$stage_dir"
    fi
}
trap cleanup EXIT

cd "$repo_dir"
build_settings=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
)
if [[ "$mode" == "development" ]]; then
    build_settings+=(
        CODE_SIGN_IDENTITY=-
        DEVELOPMENT_TEAM=
        ENABLE_HARDENED_RUNTIME=NO
    )
else
    build_settings+=(
        "CODE_SIGN_IDENTITY=$developer_identity"
        "DEVELOPMENT_TEAM=$development_team"
        ENABLE_HARDENED_RUNTIME=YES
        OTHER_CODE_SIGN_FLAGS=--timestamp
    )
fi

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
    "${build_settings[@]}"

actual_version="$(plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")"
actual_build="$(plutil -extract CFBundleVersion raw "$app_path/Contents/Info.plist")"
[[ "$actual_version" == "$version" ]] || fail "built app version is $actual_version"
[[ "$actual_build" == "$build_number" ]] || fail "built app number is $actual_build"

if [[ "$mode" == "development" ]]; then
    codesign --force --deep --sign - "$app_path"
    codesign --verify --deep --strict --verbose=2 "$app_path"
else
    codesign --verify --deep --strict --verbose=2 "$app_path"
    signature_details="$(codesign -dv --verbose=4 "$app_path" 2>&1)"
    print -r -- "$signature_details" | grep -Eq '^Authority=Developer ID Application:' \
        || fail "built app is not signed with Developer ID Application"
    print -r -- "$signature_details" | grep -Fq "TeamIdentifier=$development_team" \
        || fail "built app team identifier does not match"
    print -r -- "$signature_details" | grep -Eq '^flags=.*runtime' \
        || fail "built app does not enable Hardened Runtime"
fi

if plutil -extract SUEnableInstallerLauncherService raw "$app_path/Contents/Info.plist" >/dev/null 2>&1; then
    fail "non-sandboxed builds must use Sparkle's in-process installer launcher"
fi

mkdir -p "$stage_dir/volume" "$dist_dir"
ditto "$app_path" "$stage_dir/volume/Lumen.app"
ln -s /Applications "$stage_dir/volume/Applications"
if [[ "$mode" == "development" ]]; then
    print 'LOCAL DEVELOPMENT ARTIFACT — DO NOT PUBLISH' > "$stage_dir/volume/DEVELOPMENT-ONLY.txt"
fi

hdiutil create \
    -volname "Lumen $version" \
    -srcfolder "$stage_dir/volume" \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$temp_dmg"
hdiutil verify "$temp_dmg" >/dev/null

if [[ "$mode" == "development" ]]; then
    mv "$temp_dmg" "$output_path"
    print "Created local-only artifact: $output_path"
    shasum -a 256 "$output_path"
    exit 0
fi

codesign --force --sign "$developer_identity" --timestamp "$temp_dmg"
xcrun notarytool submit "$temp_dmg" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$temp_dmg"
xcrun stapler validate "$temp_dmg"

sparkle_dir="$derived_dir/SourcePackages/artifacts/sparkle/Sparkle"
generate_appcast="$sparkle_dir/bin/generate_appcast"
generate_keys="$sparkle_dir/bin/generate_keys"
sign_update="$sparkle_dir/bin/sign_update"
[[ -x "$generate_appcast" ]] || fail "Sparkle generate_appcast is missing"
[[ -x "$generate_keys" ]] || fail "Sparkle generate_keys is missing"
[[ -x "$sign_update" ]] || fail "Sparkle sign_update is missing"

expected_public_key="$(plutil -extract SUPublicEDKey raw "$app_path/Contents/Info.plist")"
signing_public_key="$("$generate_keys" --account "$sparkle_account" -p)"
[[ "$signing_public_key" == "$expected_public_key" ]] || fail "Sparkle signing key does not match the app"
"$generate_keys" --account "$sparkle_account" -x "$private_key_path"
chmod 600 "$private_key_path"

mkdir -p "$appcast_dir"
ditto "$temp_dmg" "$appcast_dir/Lumen-$version.dmg"
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

LUMEN_SPARKLE_SIGN_UPDATE="$sign_update" \
LUMEN_SPARKLE_KEY_FILE="$private_key_path" \
LUMEN_DEVELOPMENT_TEAM="$development_team" \
    "$script_dir/verify-release.sh" "$temp_dmg" "$version" "$build_number" "$appcast_dir/appcast.xml"

# Only verified, notarized artifacts may now affect release outputs or the live appcast.
mv "$temp_dmg" "$output_path"
ditto "$appcast_dir/appcast.xml" "$dist_dir/appcast.xml"
ditto "$appcast_dir/appcast.xml" "$tracked_appcast_path"
print "Created verified release artifact: $output_path"
shasum -a 256 "$output_path"
shasum -a 256 "$dist_dir/appcast.xml"
