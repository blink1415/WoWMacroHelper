#!/usr/bin/env bash
# Packages the addon as dist/MacroHelper-<version>.zip. The zip holds a
# MacroHelper/ folder, so it extracts straight into Interface/AddOns/.
set -euo pipefail
cd "$(dirname "$0")"

ADDON=MacroHelper
FILES=(MacroHelper.toc Builder.lua UI.lua)
version=$(sed -n 's/^## Version: *//p' "$ADDON.toc" | tr -d '\r')
zip="dist/$ADDON-$version.zip"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/$ADDON"
cp "${FILES[@]}" "$stage/$ADDON/"

mkdir -p dist
rm -f "$zip"
(cd "$stage" && zip -qr - "$ADDON") > "$zip"

echo "$zip"
