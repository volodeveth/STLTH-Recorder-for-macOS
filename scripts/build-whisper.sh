#!/bin/zsh
# Build a self-contained whisper-cli for the app bundle.
#
# Homebrew's build cannot be bundled. Its ggml links the compute backends as separate
# .so files loaded with dlopen from a directory compiled in at *its* build time
# (/opt/homebrew/Cellar/ggml/<ver>/libexec). Copying those into the app achieves
# nothing: GGML_BACKEND_PATH names a single file rather than a directory, and the
# executable's own directory is never searched. Hiding the Cellar copy proves it —
# whisper-cli crashes inside make_buft_list before reading a single sample.
#
# Built here instead with GGML_BACKEND_DL=OFF, so Metal, BLAS and CPU are linked in and
# the binary depends on nothing but macOS itself.
#
#   scripts/build-whisper.sh
set -euo pipefail

cd "$(dirname "$0")/.."

# Pinned, and not only for reproducibility: ENGINEERING_NOTES §10 quotes 8.8 % WER for a
# particular whisper, and a number measured on a version nobody recorded means nothing.
VERSION="v1.9.2"

SRC="build/whisper.cpp"
OUT_DIR="build/whisper"
OUT="$OUT_DIR/whisper-cli"

if [[ -x "$OUT" && "$(cat "$OUT_DIR/.version" 2>/dev/null)" == "$VERSION" ]]; then
  echo "==> whisper-cli $VERSION уже зібраний"
  exit 0
fi

if ! command -v cmake >/dev/null; then
  echo "❌ Потрібен cmake. Встанови: brew install cmake"
  exit 1
fi

echo "==> Беру whisper.cpp $VERSION"
if [[ -d "$SRC/.git" ]]; then
  git -C "$SRC" fetch --depth 1 origin tag "$VERSION" --no-tags
  git -C "$SRC" checkout -q "$VERSION"
else
  rm -rf "$SRC"
  git clone --quiet --depth 1 --branch "$VERSION" https://github.com/ggml-org/whisper.cpp "$SRC"
fi

echo "==> Збираю (backends лінкуються всередину)"
# GGML_NATIVE=OFF because this binary ships to other people's Macs: tuning it for the
# build machine's exact CPU is how you get an illegal instruction on someone else's.
# OPENMP=OFF drops libomp, one more thing that would otherwise have to travel along.
cmake -S "$SRC" -B "$SRC/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.4 \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_BACKEND_DL=OFF \
  -DGGML_NATIVE=OFF \
  -DGGML_OPENMP=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=OFF \
  > /dev/null

cmake --build "$SRC/build" --config Release --target whisper-cli -j"$(sysctl -n hw.ncpu)" > /dev/null

mkdir -p "$OUT_DIR"
cp "$SRC/build/bin/whisper-cli" "$OUT"
echo "$VERSION" > "$OUT_DIR/.version"

# The whole point of this script: nothing outside macOS may be left in the load
# commands, or the bundle is broken on any machine but this one.
if otool -L "$OUT" | tail -n +2 | grep -vE "^\s+(/usr/lib|/System)" | grep -q .; then
  echo "❌ Збірка не самодостатня:"
  otool -L "$OUT" | tail -n +2 | grep -vE "^\s+(/usr/lib|/System)"
  exit 1
fi

echo "✅ $OUT ($VERSION, $(du -h "$OUT" | cut -f1))"
