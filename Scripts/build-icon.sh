#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
source_icon="${1:-$project_root/App/AppIcon.png}"
output_icon="${2:-$project_root/App/AppIcon.icns}"
temporary_dir=$(mktemp -d /tmp/zerosound-appicon.XXXXXX)
iconset_dir="$temporary_dir/AppIcon.iconset"
mkdir -p "$iconset_dir"

cleanup() {
  rm -rf -- "$temporary_dir"
}
trap cleanup EXIT

width=$(sips -g pixelWidth "$source_icon" | awk '/pixelWidth:/ { print $2 }')
height=$(sips -g pixelHeight "$source_icon" | awk '/pixelHeight:/ { print $2 }')
if [[ "$width" != "1024" || "$height" != "1024" ]]; then
  print -u2 -- "App icon master must be exactly 1024x1024 pixels."
  exit 1
fi

for specification in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"
do
  size=${specification%% *}
  name=${specification#* }
  sips -z "$size" "$size" "$source_icon" --out "$iconset_dir/$name" >/dev/null
done

iconutil -c icns "$iconset_dir" -o "$output_icon"
print -r -- "$output_icon"
