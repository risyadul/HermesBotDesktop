#!/bin/bash
# Regenerates Resources/AppIcon.icns from scripts/app-icon.swift. Run after changing the drawing; commit the .icns.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
swift "$root/scripts/app-icon.swift" "$work/AppIcon.iconset"
mkdir -p "$root/Resources"
iconutil -c icns "$work/AppIcon.iconset" -o "$root/Resources/AppIcon.icns"
echo "wrote Resources/AppIcon.icns"
