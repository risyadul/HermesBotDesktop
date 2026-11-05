#!/usr/bin/env bash
# Build a release HermesBot.app, ad-hoc sign it and zip it into dist/.
# Usage: scripts/package-app.sh [version]
# Env:   HERMES_BOT_SCRATCH_PATH  SwiftPM scratch path (default: .build)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

version="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)}"
version="${version#v}"
# CFBundleShortVersionString must be numeric (1-3 dot-separated integers): reject anything else.
if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "error: version '$version' must look like 1.2.3 (pass it as the first argument)" >&2
  exit 1
fi
scratch="${HERMES_BOT_SCRATCH_PATH:-.build}"
dist="dist"
app="$dist/HermesBot.app"
zip="$dist/HermesBot-$version-macos-arm64.zip"

swift build -c release --product HermesBotApp --scratch-path "$scratch"
bin_dir="$(swift build -c release --product HermesBotApp --scratch-path "$scratch" --show-bin-path)"

rm -rf "$app" "$zip"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/HermesBotApp" "$app/Contents/MacOS/HermesBotApp"

# SwiftPM resource bundles (if any) live next to the binary.
shopt -s nullglob
for bundle in "$bin_dir"/*.bundle; do
  cp -R "$bundle" "$app/Contents/Resources/"
done
shopt -u nullglob

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.risyadul.hermesbot</string>
  <key>CFBundleName</key><string>Hermes Bot</string>
  <key>CFBundleDisplayName</key><string>Hermes Bot</string>
  <key>CFBundleExecutable</key><string>HermesBotApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist"

codesign --force --deep -s - "$app"
codesign -dv "$app"

ditto -c -k --keepParent "$app" "$zip"
echo "Created $zip"
