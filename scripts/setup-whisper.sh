#!/usr/bin/env bash
set -euo pipefail

MODEL_NAME="${1:-tiny.en-q5_1}"
WHISPER_VERSION="${WHISPER_CPP_VERSION:-v1.8.1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="$PROJECT_DIR/tools/whisper.cpp"
RUNTIME_DIR="$PROJECT_DIR/tools/runtime"

if ! command -v cmake >/dev/null 2>&1; then
  echo "cmake is required. Install it once with: brew install cmake" >&2
  exit 1
fi

mkdir -p "$PROJECT_DIR/tools" "$RUNTIME_DIR"

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  git clone --depth 1 --branch "$WHISPER_VERSION" https://github.com/ggml-org/whisper.cpp.git "$SOURCE_DIR"
fi

cmake -S "$SOURCE_DIR" -B "$SOURCE_DIR/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=OFF
cmake --build "$SOURCE_DIR/build" --config Release -j "$(sysctl -n hw.logicalcpu)"

if [[ ! -f "$SOURCE_DIR/models/ggml-$MODEL_NAME.bin" ]]; then
  "$SOURCE_DIR/models/download-ggml-model.sh" "$MODEL_NAME"
fi

cp "$SOURCE_DIR/build/bin/whisper-cli" "$RUNTIME_DIR/whisper-cli"
cp "$SOURCE_DIR/models/ggml-$MODEL_NAME.bin" "$RUNTIME_DIR/ggml-$MODEL_NAME.bin"
chmod +x "$RUNTIME_DIR/whisper-cli"

echo
echo "Open Wisper runtime is ready:"
echo "  Binary: $RUNTIME_DIR/whisper-cli"
echo "  Model:  $RUNTIME_DIR/ggml-$MODEL_NAME.bin"
