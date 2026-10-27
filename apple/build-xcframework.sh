#!/usr/bin/env bash
# Builds apple/Artifacts/CTLottie.xcframework: tlottie's C API as a static
# library for iOS, the iOS Simulator and macOS, plus a zip for SPM releases.
#
#   apple/build-xcframework.sh            # build everything
#   SKIP_ZIP=1 apple/build-xcframework.sh # skip the release zip
#
# Needs rustup with the targets listed below (the script adds missing ones).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPLE="$ROOT/apple"
WORK="$APPLE/build"
OUT="$APPLE/Artifacts"
NAME="CTLottie"

# Keep these in sync with `platforms` in Package.swift.
export IPHONEOS_DEPLOYMENT_TARGET=13.0
export MACOSX_DEPLOYMENT_TARGET=11.0

IOS_TARGETS=(aarch64-apple-ios)
SIM_TARGETS=(aarch64-apple-ios-sim x86_64-apple-ios)
MAC_TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)

arch_of() {
    case "$1" in
        aarch64-*) echo arm64 ;;
        x86_64-*) echo x86_64 ;;
        *) echo "unknown target $1" >&2; exit 1 ;;
    esac
}

# The new Apple linker wants -platform_version even for `ld -r`.
platform_version_of() {
    case "$1" in
        aarch64-apple-ios-sim)
            # Arm64 simulators start at iOS 14, and Rust's prebuilt
            # compiler_builtins for this target says so.
            echo "ios-simulator 14.0 $(xcrun --sdk iphonesimulator --show-sdk-version)" ;;
        x86_64-apple-ios)
            echo "ios-simulator $IPHONEOS_DEPLOYMENT_TARGET $(xcrun --sdk iphonesimulator --show-sdk-version)" ;;
        *-apple-ios)
            echo "ios $IPHONEOS_DEPLOYMENT_TARGET $(xcrun --sdk iphoneos --show-sdk-version)" ;;
        *-apple-darwin)
            echo "macos $MACOSX_DEPLOYMENT_TARGET $(xcrun --sdk macosx --show-sdk-version)" ;;
        *) echo "unknown target $1" >&2; exit 1 ;;
    esac
}

ensure_targets() {
    local installed
    installed="$(rustup target list --installed)"
    for target in "${IOS_TARGETS[@]}" "${SIM_TARGETS[@]}" "${MAC_TARGETS[@]}"; do
        if ! grep -qx "$target" <<<"$installed"; then
            rustup target add "$target"
        fi
    done
}

# One static library per Rust target. panic=abort because a panic can not
# unwind through `extern "C"` anyway, and it drops the unwind tables.
build_target() {
    local target="$1"
    cargo rustc \
        --manifest-path "$ROOT/Cargo.toml" \
        --release \
        --lib \
        --crate-type staticlib \
        --features c-api \
        --target "$target" \
        --target-dir "$WORK/cargo" \
        --config 'profile.release.panic="abort"'
}

# Links the archive into one object that exports only tlottie_*. Everything
# else (Rust std, compiler builtins) becomes local, so an app that links
# another Rust static library does not get duplicate symbols.
localize_symbols() {
    local target="$1" dest="$2"
    local arch platform_version
    arch="$(arch_of "$target")"
    platform_version="$(platform_version_of "$target")"
    local archive="$WORK/cargo/$target/release/libtlottie.a"
    local object="$WORK/obj/$target/tlottie.o"
    mkdir -p "$(dirname "$object")" "$(dirname "$dest")"
    # shellcheck disable=SC2086 # platform_version is three words on purpose
    ld -r -arch "$arch" \
        -platform_version $platform_version \
        -exported_symbols_list "$APPLE/exported_symbols.txt" \
        -force_load "$archive" \
        -o "$object"
    rm -f "$dest"
    libtool -static -o "$dest" "$object"
}

# Combines per-target libraries of one platform into a fat library.
platform_library() {
    local platform="$1"; shift
    local libs=()
    for target in "$@"; do
        local lib="$WORK/lib/$target/libtlottie.a"
        localize_symbols "$target" "$lib"
        libs+=("$lib")
    done
    mkdir -p "$WORK/lib/$platform"
    lipo -create "${libs[@]}" -output "$WORK/lib/$platform/libtlottie.a"
}

main() {
    ensure_targets

    for target in "${IOS_TARGETS[@]}" "${SIM_TARGETS[@]}" "${MAC_TARGETS[@]}"; do
        echo "==> cargo $target"
        build_target "$target"
    done

    echo "==> localizing symbols"
    platform_library ios "${IOS_TARGETS[@]}"
    platform_library ios-simulator "${SIM_TARGETS[@]}"
    platform_library macos "${MAC_TARGETS[@]}"

    # Headers live in Headers/CTLottie/ rather than Headers/, so two static
    # XCFrameworks in one app never both ship Headers/module.modulemap.
    local headers="$WORK/headers"
    rm -rf "$headers"
    mkdir -p "$headers/$NAME"
    cp "$ROOT/include/tlottie.h" "$headers/$NAME/tlottie.h"
    cp "$APPLE/module.modulemap" "$headers/$NAME/module.modulemap"

    echo "==> xcframework"
    rm -rf "$OUT/$NAME.xcframework"
    mkdir -p "$OUT"
    xcodebuild -create-xcframework \
        -library "$WORK/lib/ios/libtlottie.a" -headers "$headers" \
        -library "$WORK/lib/ios-simulator/libtlottie.a" -headers "$headers" \
        -library "$WORK/lib/macos/libtlottie.a" -headers "$headers" \
        -output "$OUT/$NAME.xcframework" >/dev/null
    cp "$ROOT/LICENSE" "$OUT/$NAME.xcframework/LICENSE"

    if [[ "${SKIP_ZIP:-0}" != "1" ]]; then
        echo "==> zip"
        rm -f "$OUT/$NAME.xcframework.zip"
        (cd "$OUT" && ditto -c -k --sequesterRsrc --keepParent "$NAME.xcframework" "$NAME.xcframework.zip")
        echo "checksum: $(swift package compute-checksum "$OUT/$NAME.xcframework.zip")"
    fi

    echo "==> done: $OUT/$NAME.xcframework"
}

main "$@"
