#!/usr/bin/env bash
# Build a release HermesBot.app, sign it and zip it into dist/.
#
# Usage: scripts/package-app.sh [version] [--universal] [--dry-run]
#   version      1.2.3 (default: the latest git tag, else 0.0.0)
#   --universal  one binary for Apple silicon and Intel (arm64 + x86_64, joined with lipo). Releases use it.
#                Without it: the build machine's architecture only.
#   --dry-run    print the plan (architectures, zip, signing, notarization) and exit without building
#   -h, --help   this text
#
# Env:
#   HERMES_BOT_SCRATCH_PATH   SwiftPM scratch path (default: .build)
#   DEVELOPER_ID_APPLICATION  codesign identity, e.g. "Developer ID Application: Name (TEAMID)". Set: Developer ID
#                             signature with the hardened runtime and scripts/HermesBot.entitlements. Unset: ad-hoc.
#   NOTARY_PROFILE            `xcrun notarytool store-credentials` profile. With DEVELOPER_ID_APPLICATION, the app
#                             is notarized (notarytool submit --wait) and the ticket stapled before zipping.
#   NOTARY_KEYCHAIN           keychain holding NOTARY_PROFILE when it is not in the default search list (CI)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

usage() { awk 'NR > 3 && /^# Usage:/ { on = 1 } on && /^set -euo/ { exit } on { sub(/^# ?/, ""); print }' "$0"; }

version=""
universal=0
dry_run=0

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --universal) universal=1 ;;
      --dry-run) dry_run=1 ;;
      -h|--help) usage; exit 0 ;;
      -*) echo "error: unknown option '$1'" >&2; usage >&2; exit 2 ;;
      *)
        if [[ -n "$version" ]]; then
          echo "error: more than one version given ('$version', '$1')" >&2
          exit 2
        fi
        version="$1"
        ;;
    esac
    shift
  done
}

parse_args "$@"
if [[ -z "$version" ]]; then
  version="$(git describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)"
fi
version="${version#v}"
# CFBundleShortVersionString must be numeric (1-3 dot-separated integers): reject anything else.
if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "error: version '$version' must look like 1.2.3 (pass it as the first argument)" >&2
  exit 1
fi
scratch="${HERMES_BOT_SCRATCH_PATH:-.build}"
dist="dist"
app="$dist/HermesBot.app"
entitlements="scripts/HermesBot.entitlements"
if [[ "$universal" == 1 ]]; then
  arches="arm64 x86_64"
  flavor="universal"
else
  arches="$(uname -m)"
  flavor="$arches"
fi
zip="$dist/HermesBot-$version-macos-$flavor.zip"

signing_mode() {
  if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then echo developer-id; else echo ad-hoc; fi
}

notarizing() {
  [[ -n "${DEVELOPER_ID_APPLICATION:-}" && -n "${NOTARY_PROFILE:-}" ]]
}

print_plan() {
  echo "version: $version"
  echo "architectures: $arches"
  echo "app: $app"
  echo "zip: $zip"
  if [[ "$(signing_mode)" == developer-id ]]; then
    echo "signing: Developer ID \"$DEVELOPER_ID_APPLICATION\" (hardened runtime, $entitlements)"
  else
    echo "signing: ad-hoc (set DEVELOPER_ID_APPLICATION to sign with a Developer ID)"
  fi
  if notarizing; then
    echo "notarization: notarytool profile \"$NOTARY_PROFILE\", then stapled"
  else
    echo "notarization: skipped (needs DEVELOPER_ID_APPLICATION and NOTARY_PROFILE)"
  fi
}

check_notary_config() {
  if [[ -n "${NOTARY_PROFILE:-}" && -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    echo "error: NOTARY_PROFILE is set but DEVELOPER_ID_APPLICATION is not: notarization needs a Developer ID signature" >&2
    exit 1
  fi
}

check_signing_identity() {
  if [[ "$(signing_mode)" == developer-id ]] && ! security find-identity -v -p codesigning | grep -qF "$DEVELOPER_ID_APPLICATION"; then
    echo "error: no valid codesigning identity matching DEVELOPER_ID_APPLICATION in the keychain search list" >&2
    exit 1
  fi
}

# Builds HermesBotApp for $arches. Sets bin_dir (where SwiftPM resource bundles are) and binary (what ships).
build_binary() {
  if [[ "$universal" != 1 ]]; then
    swift build -c release --product HermesBotApp --scratch-path "$scratch"
    bin_dir="$(swift build -c release --product HermesBotApp --scratch-path "$scratch" --show-bin-path)"
    binary="$bin_dir/HermesBotApp"
    return
  fi
  local slices=() arch dir
  bin_dir=""
  for arch in $arches; do
    swift build -c release --product HermesBotApp --scratch-path "$scratch" --arch "$arch"
    dir="$(swift build -c release --product HermesBotApp --scratch-path "$scratch" --arch "$arch" --show-bin-path)"
    slices+=("$dir/HermesBotApp")
    [[ -n "$bin_dir" ]] || bin_dir="$dir"
  done
  binary="$scratch/HermesBotApp-universal"
  lipo -create -output "$binary" "${slices[@]}"
  verify_architectures "$binary"
}

# Fails unless $1 has a slice for every architecture in $arches.
verify_architectures() {
  local have arch
  lipo -info "$1"
  have=" $(lipo -archs "$1") "
  for arch in $arches; do
    if [[ "$have" != *" $arch "* ]]; then
      echo "error: $1 has no $arch slice" >&2
      exit 1
    fi
  done
}

sign_app() {
  if [[ "$(signing_mode)" == developer-id ]]; then
    codesign --force --options runtime --timestamp --entitlements "$entitlements" \
      --sign "$DEVELOPER_ID_APPLICATION" "$app"
  else
    codesign --force --deep -s - "$app"
    echo "note: ad-hoc signature: macOS asks users to confirm the first launch (README, Download / packaging)."
  fi
  codesign --verify --strict --verbose=2 "$app"
  codesign -dv "$app"
}

notarize_app() {
  local submission="$dist/HermesBot-$version-notarize.zip" out status id
  local args=(--keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
  [[ -z "${NOTARY_KEYCHAIN:-}" ]] || args+=(--keychain "$NOTARY_KEYCHAIN")
  ditto -c -k --keepParent "$app" "$submission"
  if ! out="$(xcrun notarytool submit "$submission" "${args[@]}")"; then
    rm -f "$submission"
    echo "$out" >&2
    echo "error: notarytool submit failed" >&2
    exit 1
  fi
  rm -f "$submission"
  echo "$out"
  status="$(plutil -extract status raw -o - - <<<"$out" 2>/dev/null || echo unknown)"
  if [[ "$status" != Accepted ]]; then
    id="$(plutil -extract id raw -o - - <<<"$out" 2>/dev/null || echo '<submission id>')"
    echo "error: notarization status '$status'; details: xcrun notarytool log $id --keychain-profile \"$NOTARY_PROFILE\"" >&2
    exit 1
  fi
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=2 "$app"
}

check_notary_config
print_plan
if [[ "$dry_run" == 1 ]]; then
  exit 0
fi
check_signing_identity
build_binary

rm -rf "$app" "$zip"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/HermesBotApp"

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

sign_app
if notarizing; then
  notarize_app
else
  echo "note: not notarized (needs DEVELOPER_ID_APPLICATION and NOTARY_PROFILE)."
fi
verify_architectures "$app/Contents/MacOS/HermesBotApp"

ditto -c -k --keepParent "$app" "$zip"
echo "Created $zip"
