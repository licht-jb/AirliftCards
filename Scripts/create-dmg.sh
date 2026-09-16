#!/bin/bash

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <app-path> <output-dmg>" >&2
    exit 64
fi

app_path=$1
output_path=$2

if [ ! -d "$app_path" ]; then
    echo "app not found: $app_path" >&2
    exit 66
fi

output_directory=$(dirname "$output_path")
mkdir -p "$output_directory"
staging_directory=$(mktemp -d "${TMPDIR:-/tmp}/airlift-cards-dmg.XXXXXX")
image_directory=$(mktemp -d "$output_directory/.airlift-cards-dmg.XXXXXX")
trap 'rm -rf "$staging_directory" "$image_directory"' EXIT

ditto "$app_path" "$staging_directory/Airlift Cards.app"
ln -s /Applications "$staging_directory/Applications"

temporary_output="$image_directory/$(basename "$output_path")"
diskutil image create from \
    --volumeName "Airlift Cards" \
    --format UDZO \
    "$staging_directory" \
    "$temporary_output"
mv -f "$temporary_output" "$output_path"
