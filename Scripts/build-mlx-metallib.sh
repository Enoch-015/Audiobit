#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 OUTPUT_PATH" >&2
  exit 2
fi

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE_ROOT="$ROOT/.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
BUILD_ROOT="$ROOT/.build/mlx-metal"
OUTPUT=$1

if [ ! -d "$SOURCE_ROOT" ]; then
  echo "MLX sources are missing; run swift package resolve first." >&2
  exit 1
fi

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"

for source in "$SOURCE_ROOT"/*.metal "$SOURCE_ROOT"/steel/attn/kernels/*.metal; do
  name=$(basename "$source" .metal)
  xcrun -sdk macosx metal \
    -std=metal3.2 \
    -Wno-c++17-extensions \
    -c "$source" \
    -I"$SOURCE_ROOT" \
    -o "$BUILD_ROOT/$name.air"
done

xcrun -sdk macosx metallib "$BUILD_ROOT"/*.air -o "$BUILD_ROOT/mlx.metallib"
mkdir -p "$(dirname "$OUTPUT")"
cp "$BUILD_ROOT/mlx.metallib" "$OUTPUT"
