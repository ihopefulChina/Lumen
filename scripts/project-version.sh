#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project_file="$repo_root/Lumen.xcodeproj/project.pbxproj"

read_setting() {
    setting=$1
    values=$(sed -nE "s/^[[:space:]]*$setting = ([^;]+);/\\1/p" "$project_file" | sort -u)
    count=$(printf '%s\n' "$values" | sed '/^$/d' | wc -l | tr -d ' ')
    if [ "$count" != "1" ]; then
        printf 'Expected one unique %s value in %s, found: %s\n' "$setting" "$project_file" "$values" >&2
        exit 1
    fi
    printf '%s' "$values"
}

version=$(read_setting MARKETING_VERSION)
build=$(read_setting CURRENT_PROJECT_VERSION)
printf '%s %s\n' "$version" "$build"
