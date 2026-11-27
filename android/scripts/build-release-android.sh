#!/usr/bin/env bash
set -euo pipefail

# Builds a slim production-ready Charkle Android Release APK:
# 1. Runs Rust unit tests in charkle-android-ffi
# 2. Cross-compiles charkle-core + UniFFI with [profile.release] (opt-level="s", thin LTO, stripped)
# 3. Runs Kotlin unit tests & R8-minified + resource-shrunk :app:assembleRelease
#
# Optional signing via environment variables:
#   CHARKLE_KEYSTORE_PATH, CHARKLE_KEYSTORE_PASS, CHARKLE_KEY_ALIAS, CHARKLE_KEY_PASS

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export JAVA_HOME="${JAVA_HOME:-$HOME/.local/jdk-21/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export PATH="$JAVA_HOME/bin:$HOME/.cargo/bin:$HOME/.local/bin:$ANDROID_HOME/platform-tools:$PATH"
BUILD_ROOT="${CHARKLE_ANDROID_BUILD_DIR:-$HOME/.cache/charkle-android-build}"
ABIS="${CHARKLE_ANDROID_ABIS:-arm64-v8a}"

echo "==> 1/4 Running Rust charkle-android-ffi unit tests"
cargo test --manifest-path "$ROOT_DIR/rust/charkle-android-ffi/Cargo.toml"

echo "==> 2/4 Building slim Rust Release native libs (ABIs: $ABIS)"
CHARKLE_RUST_PROFILE=release CHARKLE_ANDROID_ABIS="$ABIS" "$ROOT_DIR/scripts/build-rust-android.sh"

echo "==> 3/4 Running Kotlin unit tests & R8-minified Release APK build"
pushd "$ROOT_DIR" >/dev/null
./gradlew :app:testDebugUnitTest :app:assembleRelease --no-configuration-cache
popd >/dev/null

APK_DIR="$BUILD_ROOT/app/outputs/apk/release"
echo "==> 4/4 Release artifacts ready:"
ls -lh "$APK_DIR"/*.apk
ls -lh "$ROOT_DIR/app/src/main/jniLibs/"*/*.so
