#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FFI_DIR="$ROOT_DIR/rust/charkle-android-ffi"
JNI_LIBS_DIR="$ROOT_DIR/app/src/main/jniLibs"
KOTLIN_OUT_DIR="$ROOT_DIR/app/src/main/java"

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"

if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
  SDK_ROOT="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
  NDK_DIR="$(ls -d "$SDK_ROOT/ndk/"* 2>/dev/null | sort -V | tail -n 1 || true)"
  if [[ -z "$NDK_DIR" ]]; then
    echo "ERROR: ANDROID_NDK_HOME not set and no NDK found under $SDK_ROOT/ndk" >&2
    exit 1
  fi
  export ANDROID_NDK_HOME="$NDK_DIR"
fi

PROFILE="${CHARKLE_RUST_PROFILE:-release}"
TARGET_ABIS="${CHARKLE_ANDROID_ABIS:-arm64-v8a}"

echo "==> Building charkle-android-ffi ($PROFILE) for ABIs: $TARGET_ABIS"
echo "    ANDROID_NDK_HOME=$ANDROID_NDK_HOME"

mkdir -p "$JNI_LIBS_DIR" "$KOTLIN_OUT_DIR"

CARGO_NDK_ARGS=(-o "$JNI_LIBS_DIR" --platform 26)
for abi in $TARGET_ABIS; do
  CARGO_NDK_ARGS+=(-t "$abi")
done

pushd "$FFI_DIR" >/dev/null
if [[ "$PROFILE" == "release" ]]; then
  cargo ndk "${CARGO_NDK_ARGS[@]}" build --release
  FIRST_LIB="$JNI_LIBS_DIR/$(echo "$TARGET_ABIS" | awk '{print $1}')/libcharkle_android_ffi.so"
else
  cargo ndk "${CARGO_NDK_ARGS[@]}" build
  FIRST_LIB="$JNI_LIBS_DIR/$(echo "$TARGET_ABIS" | awk '{print $1}')/libcharkle_android_ffi.so"
fi

echo "==> Generating UniFFI Kotlin bindings from $FIRST_LIB"
cargo run --bin uniffi-bindgen -- generate \
  --library "$FIRST_LIB" \
  --language kotlin \
  --out-dir "$KOTLIN_OUT_DIR"
popd >/dev/null

NDK_STRIP="$(ls "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/"*/bin/llvm-strip 2>/dev/null | head -n 1 || true)"
if [[ -n "$NDK_STRIP" && "$PROFILE" != "release" ]]; then
  echo "==> Stripping debug info from dev .so to speed up APK install"
  for lib in "$JNI_LIBS_DIR"/*/libcharkle_android_ffi.so; do
    "$NDK_STRIP" --strip-debug "$lib"
  done
fi

echo "==> Done! Native libs:"
ls -lh "$JNI_LIBS_DIR"/*/libcharkle_android_ffi.so
