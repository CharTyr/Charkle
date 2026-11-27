#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export JAVA_HOME="${JAVA_HOME:-$HOME/.local/jdk-21/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export PATH="$JAVA_HOME/bin:$HOME/.cargo/bin:$HOME/.local/bin:$ANDROID_HOME/platform-tools:$PATH"

echo "==> 1/3 Running Rust charkle-android-ffi unit tests"
cargo test --manifest-path "$ROOT_DIR/rust/charkle-android-ffi/Cargo.toml"

echo "==> 2/3 Cross-compiling Rust native libs & UniFFI Kotlin bindings"
"$ROOT_DIR/scripts/build-rust-android.sh"

echo "==> 3/3 Building Android Debug APK"
BUILD_ROOT="${CHARKLE_ANDROID_BUILD_DIR:-$HOME/.cache/charkle-android-build}"
pushd "$ROOT_DIR" >/dev/null
./gradlew :app:assembleDebug :app:testDebugUnitTest --no-configuration-cache
popd >/dev/null

echo "==> Debug APK ready:"
ls -lh "$BUILD_ROOT/app/outputs/apk/debug/app-debug.apk"
