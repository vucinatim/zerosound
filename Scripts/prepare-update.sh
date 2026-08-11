#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
info="$project_root/App/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")
archive="$project_root/.build/ZeroSound-$version-macOS-universal.zip"
sparkle_tools="$project_root/.build/artifacts/sparkle/Sparkle/bin"
generate_appcast="$sparkle_tools/generate_appcast"
key_account="com.zerosound.updates"
release_base_url="${ZEROSOUND_RELEASE_BASE_URL:-https://github.com/vucinatim/zerosound/releases/download/v$version}"
release_notes="${1:-}"
site="$project_root/site"

if [[ ! -f "$archive" ]]; then
  print -u2 -- "Missing $archive. Run ./Scripts/build-app.sh release first."
  exit 1
fi
if [[ ! -x "$generate_appcast" ]]; then
  print -u2 -- "Sparkle tools are unavailable. Run swift package resolve first."
  exit 1
fi
if [[ -n "$release_notes" && ! -f "$release_notes" ]]; then
  print -u2 -- "Release notes not found: $release_notes"
  exit 1
fi
if [[ "$release_base_url" != https://* ]]; then
  print -u2 -- "ZEROSOUND_RELEASE_BASE_URL must use HTTPS."
  exit 1
fi

staging=$(mktemp -d "$project_root/.build/zerosound-update.XXXXXX")
cleanup() { rm -rf -- "$staging" }
trap cleanup EXIT

archive_name="${archive:t}"
cp "$archive" "$staging/$archive_name"
if [[ -n "$release_notes" ]]; then
  release_notes_name="${archive_name:r}.md"
  cp "$release_notes" "$staging/$release_notes_name"
fi
if [[ -f "$site/appcast.xml" ]]; then
  cp "$site/appcast.xml" "$staging/appcast.xml"
fi

"$generate_appcast" \
  --account "$key_account" \
  --download-url-prefix "${release_base_url%/}/" \
  --embed-release-notes \
  --link "https://github.com/vucinatim/zerosound" \
  --maximum-versions 5 \
  --maximum-deltas 0 \
  "$staging"

generated="$staging/appcast.xml"
has_build=false
if grep -Fq "sparkle:version=\"$build\"" "$generated" \
  || grep -Fq "<sparkle:version>$build</sparkle:version>" "$generated"; then
  has_build=true
fi
if [[ ! -f "$generated" ]] \
  || [[ "$has_build" != true ]] \
  || ! grep -Fq 'sparkle:edSignature=' "$generated" \
  || ! grep -Fq "$release_base_url/$archive_name" "$generated"; then
  print -u2 -- "Generated appcast did not contain the expected signed v$version update."
  exit 1
fi

mkdir -p "$site"
cp "$generated" "$site/appcast.xml"
if [[ -n "$release_notes" && -f "$staging/$release_notes_name" ]]; then
  cp "$staging/$release_notes_name" "$site/$release_notes_name"
fi
shasum -a 256 "$archive" > "$project_root/.build/ZeroSound-$version-SHA256SUMS"

print -r -- "Prepared ZeroSound $version ($build) update metadata:"
print -r -- "  $archive"
print -r -- "  $site/appcast.xml"
print -r -- "  $project_root/.build/ZeroSound-$version-SHA256SUMS"
