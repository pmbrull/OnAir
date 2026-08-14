#!/usr/bin/env bash
# Regenerate Resources/AppIcon.icns from scripts/make-icon.swift. The Swift file is the source of
# truth for the icon; this packs its PNGs with iconutil (a system binary — present without Xcode).
set -euo pipefail
cd "$(dirname "$0")/.."

iconset=.build/AppIcon.iconset
rm -rf "$iconset"
mkdir -p "$iconset"

swift scripts/make-icon.swift "$iconset"
iconutil -c icns "$iconset" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns ($(du -h Resources/AppIcon.icns | cut -f1 | tr -d ' '))"
