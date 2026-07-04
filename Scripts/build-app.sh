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
BUILD_NUMBER=${AUDIBIT_BUILD_NUMBER:-$(git rev-list --count HEAD)}
SHORT_VERSION=${AUDIBIT_SHORT_VERSION:-1.1.0}
SOURCE_COMMIT=${AUDIBIT_SOURCE_COMMIT:-$(git rev-parse HEAD)}
SPARKLE_FRAMEWORK=$(find "$ROOT/.build/artifacts" -path '*/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework' -print -quit)

if [ -z "$SPARKLE_FRAMEWORK" ]; then
  echo "Sparkle.framework was not resolved. Run 'swift package resolve'." >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"
cp "$ROOT/.build/release/DocumentReader" "$CONTENTS/MacOS/DocumentReader"
cp -R "$ROOT/.build/artifacts/lame-xcframework/LAME/LAME.xcframework/macos-arm64_x86_64/LAME.framework" "$CONTENTS/Frameworks/"
cp -R "$SPARKLE_FRAMEWORK" "$CONTENTS/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS/MacOS/DocumentReader"
"$ROOT/Scripts/build-mlx-metallib.sh" "$CONTENTS/MacOS/mlx.metallib"
cp "$ROOT/Support/Info.plist" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Add :AudibitSourceCommit string $SOURCE_COMMIT" "$CONTENTS/Info.plist"
cp "$ROOT/Support/Audibit.icns" "$CONTENTS/Resources/Audibit.icns"
find -L "$ROOT/.build/release" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$CONTENTS/Resources/" \;
codesign --force --deep --sign - "$APP"

echo "$APP"
