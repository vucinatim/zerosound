#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
configuration="${1:-release}"
build_root="$project_root/.build"
app_bundle="$build_root/ZeroSound.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_root/App/Info.plist")

if [[ "$configuration" == "release" ]]; then
  arm_build="$project_root/.build-arm64"
  intel_build="$project_root/.build-x86_64"
  swift build --package-path "$project_root" -c release \
    --triple arm64-apple-macosx14.2 --scratch-path "$arm_build"
  swift build --package-path "$project_root" -c release \
    --triple x86_64-apple-macosx14.2 --scratch-path "$intel_build"
  arm_binary="$arm_build/arm64-apple-macosx/release/ZeroSound"
  intel_binary="$intel_build/x86_64-apple-macosx/release/ZeroSound"
else
  swift build --package-path "$project_root" -c "$configuration"
  binary_path=$(swift build --package-path "$project_root" -c "$configuration" --show-bin-path)
fi

rm -rf -- "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS"
mkdir -p "$app_bundle/Contents/Resources"
mkdir -p "$app_bundle/Contents/Frameworks"
cp "$project_root/App/Info.plist" "$app_bundle/Contents/Info.plist"
cp "$project_root/App/AppIcon.icns" "$app_bundle/Contents/Resources/AppIcon.icns"
if [[ "$configuration" == "release" ]]; then
  xcrun lipo -create "$arm_binary" "$intel_binary" \
    -output "$app_bundle/Contents/MacOS/ZeroSound"
  sparkle_framework="$arm_build/arm64-apple-macosx/release/Sparkle.framework"
else
  cp "$binary_path/ZeroSound" "$app_bundle/Contents/MacOS/ZeroSound"
  sparkle_framework="$binary_path/Sparkle.framework"
fi
ditto "$sparkle_framework" "$app_bundle/Contents/Frameworks/Sparkle.framework"

app_binary="$app_bundle/Contents/MacOS/ZeroSound"
if ! otool -l "$app_binary" \
  | awk '/cmd LC_RPATH/{getline; getline; print $2}' \
  | grep -Fxq '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$app_binary"
fi

# SwiftPM can add an Xcode-version-specific compatibility rpath. Release bundles use the system
# Swift runtime and the explicitly bundled Sparkle framework instead.
while IFS= read -r rpath; do
  if [[ "$rpath" == /*/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-*/* ]]; then
    install_name_tool -delete_rpath "$rpath" "$app_binary"
  fi
done < <(otool -l "$app_binary" | awk '/cmd LC_RPATH/{getline; getline; if (!seen[$2]++) print $2}')

sign_identity="${ZEROSOUND_SIGN_IDENTITY:-auto}"
if [[ "$sign_identity" == "auto" ]]; then
  sign_identity=$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
    | head -n 1)
  sign_identity="${sign_identity:--}"
fi

sign_arguments=(--force --sign "$sign_identity")
sparkle_version="$app_bundle/Contents/Frameworks/Sparkle.framework/Versions/B"
component_sign_arguments=(
  --force
  --sign "$sign_identity"
  --options runtime
)
if [[ "$sign_identity" == Developer\ ID\ Application:* ]]; then
  component_sign_arguments+=(--timestamp)
  sign_arguments+=(
    --options runtime
    --timestamp
    --entitlements "$project_root/App/ZeroSound.entitlements"
  )
fi
codesign "${component_sign_arguments[@]}" "$sparkle_version/XPCServices/Installer.xpc"
codesign "${component_sign_arguments[@]}" \
  --preserve-metadata=entitlements \
  "$sparkle_version/XPCServices/Downloader.xpc"
codesign "${component_sign_arguments[@]}" "$sparkle_version/Autoupdate"
codesign "${component_sign_arguments[@]}" "$sparkle_version/Updater.app"
codesign "${component_sign_arguments[@]}" \
  "$app_bundle/Contents/Frameworks/Sparkle.framework"
codesign "${sign_arguments[@]}" "$app_bundle"
codesign --verify --deep --strict "$app_bundle"

if [[ "$configuration" == "release" ]]; then
  archive="$build_root/ZeroSound-$version-macOS-universal.zip"
  rm -f -- "$archive"
  ditto -c -k --sequesterRsrc --keepParent "$app_bundle" "$archive"
  if [[ -n "${ZEROSOUND_NOTARY_PROFILE:-}" ]]; then
    if [[ "$sign_identity" != Developer\ ID\ Application:* ]]; then
      print -u2 -- "Notarization requires a Developer ID Application identity."
      exit 1
    fi
    xcrun notarytool submit "$archive" \
      --keychain-profile "$ZEROSOUND_NOTARY_PROFILE" --wait
    xcrun stapler staple "$app_bundle"
    xcrun stapler validate "$app_bundle"
    rm -f -- "$archive"
    ditto -c -k --sequesterRsrc --keepParent "$app_bundle" "$archive"
  fi
  print -r -- "$archive"
fi

print -r -- "$app_bundle"
