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

# App Intents (D7, Shortcuts actions): Shortcuts finds them through Metadata.appintents, which Xcode generates at
# build time and SwiftPM does not. So the compiler also writes the intents' constant values
# (HermesBotApp.swiftconstvalues) and appintentsmetadataprocessor turns them into the metadata bundle below.
case "$scratch" in /*) intents_dir="$scratch/appintents" ;; *) intents_dir="$(pwd)/$scratch/appintents" ;; esac
mkdir -p "$intents_dir"
cat > "$intents_dir/protocols.json" <<'JSON'
["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutsProvider","DynamicOptionsProvider","IntentValueQuery"]
JSON
const_flags=(-Xswiftc -emit-const-values
             -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc "$intents_dir/protocols.json")

swift build -c release --product HermesBotApp --scratch-path "$scratch" "${const_flags[@]}"
bin_dir="$(swift build -c release --product HermesBotApp --scratch-path "$scratch" "${const_flags[@]}" --show-bin-path)"

rm -rf "$app" "$zip"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/HermesBotApp" "$app/Contents/MacOS/HermesBotApp"

# SwiftPM resource bundles (if any) live next to the binary.
shopt -s nullglob
for bundle in "$bin_dir"/*.bundle; do
  cp -R "$bundle" "$app/Contents/Resources/"
done
shopt -u nullglob

# Metadata.appintents for the Shortcuts actions (see above). Needs Xcode (not only the Command Line Tools).
if processor="$(xcrun --find appintentsmetadataprocessor 2>/dev/null)"; then
  find "$(pwd)/Sources/HermesBotApp" -name '*.swift' | sort > "$intents_dir/sources.txt"
  echo "$bin_dir/HermesBotApp.build/HermesBotApp.swiftconstvalues" > "$intents_dir/constvalues.txt"
  "$processor" --output "$app/Contents/Resources" \
    --toolchain-dir "$(dirname "$(dirname "$(dirname "$processor")")")" \
    --module-name HermesBotApp --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
    --platform-family macOS --deployment-target 14.0 --target-triple arm64-apple-macos14.0 \
    --source-file-list "$intents_dir/sources.txt" --swift-const-vals-list "$intents_dir/constvalues.txt"
  test -d "$app/Contents/Resources/Metadata.appintents" || { echo "error: no Metadata.appintents was produced" >&2; exit 1; }
else
  echo "warning: appintentsmetadataprocessor not found (install Xcode): the Shortcuts actions will not be listed" >&2
fi

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
  <!-- D6: Services → Send to Hermes Bot (selected text, Finder files). HermesServicesProvider.sendToHermesBot
       opens a chooser; nothing is sent until the user presses Send there. -->
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Send to Hermes Bot</string></dict>
      <key>NSMessage</key><string>sendToHermesBot</string>
      <key>NSPortName</key><string>Hermes Bot</string>
      <key>NSSendTypes</key>
      <array>
        <string>NSStringPboardType</string>
        <string>public.utf8-plain-text</string>
        <string>NSFilenamesPboardType</string>
        <string>public.file-url</string>
      </array>
      <key>NSSendFileTypes</key><array><string>public.item</string></array>
      <key>NSRequiredContext</key><dict/>
    </dict>
  </array>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist"

codesign --force --deep -s - "$app"
codesign -dv "$app"

ditto -c -k --keepParent "$app" "$zip"
echo "Created $zip"
