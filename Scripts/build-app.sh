#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ "$(uname -m)" != "arm64" ]; then
  echo "Kokoro Enhanced Voice requires an Apple Silicon Mac." >&2
  exit 1
fi

swift build -c release

APP="$ROOT/.build/app/Audibit.app"
CONTENTS="$APP/Contents"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"
cp "$ROOT/.build/release/DocumentReader" "$CONTENTS/MacOS/DocumentReader"
cp -R "$ROOT/.build/artifacts/lame-xcframework/LAME/LAME.xcframework/macos-arm64_x86_64/LAME.framework" "$CONTENTS/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS/MacOS/DocumentReader"
"$ROOT/Scripts/build-mlx-metallib.sh" "$CONTENTS/MacOS/mlx.metallib"
cp "$ROOT/Support/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Support/Audibit.icns" "$CONTENTS/Resources/Audibit.icns"
find -L "$ROOT/.build/release" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$CONTENTS/Resources/" \;
codesign --force --deep --sign - "$APP"

echo "$APP"
