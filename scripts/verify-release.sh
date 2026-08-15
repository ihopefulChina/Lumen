#!/bin/zsh
set -euo pipefail

if [[ "$#" != "4" ]]; then
    print -u2 "Usage: scripts/verify-release.sh <dmg> <version> <build> <appcast>"
    exit 64
fi

dmg_path="${1:A}"
expected_version="$2"
expected_build="$3"
appcast_path="${4:A}"
expected_team="${LUMEN_DEVELOPMENT_TEAM:-}"
sign_update="${LUMEN_SPARKLE_SIGN_UPDATE:-}"
sparkle_key_file="${LUMEN_SPARKLE_KEY_FILE:-}"

fail() {
    print -u2 "Release verification failed: $1"
    exit 1
}

[[ -f "$dmg_path" ]] || fail "DMG does not exist"
[[ -f "$appcast_path" ]] || fail "appcast does not exist"
[[ -n "$expected_team" ]] || fail "LUMEN_DEVELOPMENT_TEAM is required"
[[ -x "$sign_update" ]] || fail "LUMEN_SPARKLE_SIGN_UPDATE must point to sign_update"
[[ -f "$sparkle_key_file" ]] || fail "LUMEN_SPARKLE_KEY_FILE is required"

stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/lumen-verify-release.XXXXXX")"
mount_dir="$stage_dir/mount"
mounted=0
cleanup() {
    if [[ "$mounted" == "1" ]]; then
        hdiutil detach "$mount_dir" -quiet || true
    fi
    if [[ "$stage_dir" == "${TMPDIR:-/tmp}"/lumen-verify-release.* ]]; then
        rm -rf "$stage_dir"
    fi
}
trap cleanup EXIT

hdiutil verify "$dmg_path" >/dev/null
codesign --verify --strict --verbose=2 "$dmg_path"
xcrun stapler validate "$dmg_path"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"

mkdir -p "$mount_dir"
hdiutil attach "$dmg_path" -readonly -nobrowse -mountpoint "$mount_dir" >/dev/null
mounted=1
app_path="$mount_dir/Lumen.app"
[[ -d "$app_path" ]] || fail "mounted DMG does not contain Lumen.app"

actual_version="$(plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")"
actual_build="$(plutil -extract CFBundleVersion raw "$app_path/Contents/Info.plist")"
[[ "$actual_version" == "$expected_version" ]] || fail "expected version $expected_version, found $actual_version"
[[ "$actual_build" == "$expected_build" ]] || fail "expected build $expected_build, found $actual_build"

executable_name="$(plutil -extract CFBundleExecutable raw "$app_path/Contents/Info.plist")"
executable_path="$app_path/Contents/MacOS/$executable_name"
[[ -x "$executable_path" ]] || fail "app executable is missing"
architectures="$(lipo -archs "$executable_path")"
[[ "$architectures" == "arm64" ]] || fail "expected arm64-only executable, found: $architectures"

codesign --verify --deep --strict --verbose=2 "$app_path"
signature_details="$(codesign -dv --verbose=4 "$app_path" 2>&1)"
print -r -- "$signature_details" | grep -Eq '^Authority=Developer ID Application:' \
    || fail "Developer ID Application authority is missing"
print -r -- "$signature_details" | grep -Fq "TeamIdentifier=$expected_team" \
    || fail "TeamIdentifier does not match LUMEN_DEVELOPMENT_TEAM"
print -r -- "$signature_details" | grep -Eq '^flags=.*runtime' \
    || fail "Hardened Runtime flag is missing"
print -r -- "$signature_details" | grep -Eq '^Timestamp=.+' \
    || fail "secure timestamp is missing"
if print -r -- "$signature_details" | grep -Fq 'Timestamp=none'; then
    fail "secure timestamp is missing"
fi

spctl --assess --type execute --verbose=2 "$app_path"

declared_length="$(xmllint --xpath "string(//*[local-name()='item' and *[local-name()='version' and text()='$expected_build']]/*[local-name()='enclosure']/@length)" "$appcast_path")"
signature="$(xmllint --xpath "string(//*[local-name()='item' and *[local-name()='version' and text()='$expected_build']]/*[local-name()='enclosure']/@*[local-name()='edSignature'])" "$appcast_path")"
short_version="$(xmllint --xpath "string(//*[local-name()='item' and *[local-name()='version' and text()='$expected_build']]/*[local-name()='shortVersionString'])" "$appcast_path")"
[[ "$short_version" == "$expected_version" ]] || fail "appcast version does not match"
[[ -n "$signature" ]] || fail "Sparkle signature is missing"
[[ "$declared_length" == "$(stat -f %z "$dmg_path")" ]] || fail "appcast file length does not match DMG"
"$sign_update" --verify --ed-key-file "$sparkle_key_file" "$dmg_path" "$signature"

print "Release verification passed for Lumen $expected_version ($expected_build)."
