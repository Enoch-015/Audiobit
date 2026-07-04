#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

"$ROOT/Scripts/build-app.sh"

APP="$ROOT/.build/app/Audibit.app"
DIST="$ROOT/dist"
STAGING="$ROOT/.build/dmg"
DMG="$DIST/Audibit.dmg"

rm -rf "$STAGING"
mkdir -p "$STAGING" "$DIST"
cp -R "$APP" "$STAGING/Audibit.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"

hdiutil create \
    -volname "Audibit" \
    -srcfolder "$STAGING" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$DMG"

codesign --verify --deep --strict "$APP"
hdiutil verify "$DMG"
shasum -a 256 "$DMG"

echo "$DMG"
