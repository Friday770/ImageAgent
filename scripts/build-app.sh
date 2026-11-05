#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
project_root="$PWD"
signing_identity="${IMAGEAGENT_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
  signing_identity="$(security find-identity -v -p codesigning | sed -nE '/"(Apple Development:|Developer ID Application:)/s/^[[:space:]]*[0-9]+\) ([A-Fa-f0-9]+) .*/\1/p' | head -n 1)"
fi
if [[ -z "$signing_identity" || "$signing_identity" == "-" ]]; then
  echo "A valid existing Apple Development or Developer ID identity is required. Set IMAGEAGENT_SIGNING_IDENTITY to choose one; this script does not create certificates or change Keychain access." >&2
  exit 1
fi
swift build -c release
binary_directory="$(swift build -c release --show-bin-path)"
dist_directory="$project_root/dist"
app_directory="$dist_directory/ImageAgent.app"
mkdir -p "$dist_directory"
rm -rf "$app_directory"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources"
cp "$binary_directory/ImageAgent" "$app_directory/Contents/MacOS/ImageAgent"
cp "$binary_directory/ImageAgentDiagnostics" "$dist_directory/ImageAgentDiagnostics"
icon_stage="$(mktemp -d "$dist_directory/.icon.XXXXXX")"
source_stage=""
trap 'rm -rf "$icon_stage"; if [[ -n "$source_stage" ]]; then rm -rf "$source_stage"; fi' EXIT
mkdir -p "$icon_stage/AppIcon.iconset"
for icon_size in 16 32 128 256 512; do
  sips -z "$icon_size" "$icon_size" Resources/AppIcon.png --out "$icon_stage/AppIcon.iconset/icon_${icon_size}x${icon_size}.png" >/dev/null
  retina_size="$((icon_size * 2))"
  sips -z "$retina_size" "$retina_size" Resources/AppIcon.png --out "$icon_stage/AppIcon.iconset/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
done
iconutil -c icns "$icon_stage/AppIcon.iconset" -o "$app_directory/Contents/Resources/AppIcon.icns"
test -s "$app_directory/Contents/Resources/AppIcon.icns"
cat > "$app_directory/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ImageAgent</string>
  <key>CFBundleDisplayName</key><string>ImageAgent</string>
  <key>CFBundleIdentifier</key><string>cn.mausy.ImageAgent</string>
  <key>CFBundleExecutable</key><string>ImageAgent</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.5.0</string>
  <key>CFBundleVersion</key><string>8</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
plutil -lint "$app_directory/Contents/Info.plist"
if /usr/libexec/PlistBuddy -c 'Print :ImageAgentOfflineDemoSession' "$app_directory/Contents/Info.plist" >/dev/null 2>&1; then
  echo "Production app must not contain the offline QA session key" >&2; exit 1
fi
codesign --force --deep --timestamp=none --sign "$signing_identity" --identifier cn.mausy.ImageAgent "$app_directory"
codesign --verify --deep --strict "$app_directory"
test -x "$app_directory/Contents/MacOS/ImageAgent"
ditto -c -k --sequesterRsrc --keepParent "$app_directory" "$dist_directory/ImageAgent-macOS-arm64.zip"
source_stage="$(mktemp -d "$dist_directory/.source.XXXXXX")"
mkdir -p "$source_stage/ImageAgent"
for source_item in .gitignore Package.swift Sources Tests scripts Resources README.md docs; do
  if [[ -e "$source_item" ]]; then cp -R "$source_item" "$source_stage/ImageAgent/"; fi
done
ditto -c -k --sequesterRsrc --keepParent "$source_stage/ImageAgent" "$dist_directory/ImageAgent-source.zip"
unzip -tq "$dist_directory/ImageAgent-macOS-arm64.zip"
unzip -tq "$dist_directory/ImageAgent-source.zip"
# Recoverable patches and production files must never enter the source archive.
if unzip -Z1 "$dist_directory/ImageAgent-source.zip" | rg '(^|/)(assets|recovery|\.build|artifacts)(/|$)|\.sqlite(-wal|-shm)?$|(^|/)\.env($|\.)'; then
  echo "Unexpected private/build data in source archive" >&2
  exit 1
fi
printf 'App: %s\nApp zip: %s\nSource zip: %s\nDiagnostics: %s\n' "$app_directory" "$dist_directory/ImageAgent-macOS-arm64.zip" "$dist_directory/ImageAgent-source.zip" "$dist_directory/ImageAgentDiagnostics"
