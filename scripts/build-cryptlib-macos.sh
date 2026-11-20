#!/bin/bash
# Build Synchronet-patched cryptlib for the macOS project.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DEFAULT_TERMINATOR_ANDROID="$PROJECT_ROOT/../TERMinator"
TERMINATOR_ANDROID="${TERMINATOR_ANDROID:-$DEFAULT_TERMINATOR_ANDROID}"
if [ -d "$TERMINATOR_ANDROID" ]; then
    TERMINATOR_ANDROID="$(cd "$TERMINATOR_ANDROID" && pwd)"
fi
PATCHES_DIR="$TERMINATOR_ANDROID/3rdp/build"
CRYPTLIB_ZIP="$TERMINATOR_ANDROID/3rdp/dist/cryptlib.zip"

BUILD_DIR="/private/tmp/cryptlib-macos-build"
OUTPUT_DIR="$PROJECT_ROOT/TERMinator/Bridge/cryptlib"

MACOS_MIN_VERSION="${MACOS_MIN_VERSION:-14.0}"
IOS_MIN_VERSION="${IOS_MIN_VERSION:-16.0}"

echo "=== Building Synchronet-patched cryptlib for TERMinator macOS ==="
echo "TERMinator source: $TERMINATOR_ANDROID"
echo "Build directory: $BUILD_DIR"
echo "Output directory: $OUTPUT_DIR"
echo "macOS min version: $MACOS_MIN_VERSION"
echo "iOS min version: $IOS_MIN_VERSION"

if [ ! -f "$CRYPTLIB_ZIP" ] || [ ! -d "$PATCHES_DIR" ]; then
    echo "ERROR: Could not find TERMinator cryptlib sources at: $TERMINATOR_ANDROID"
    echo "Set TERMINATOR_ANDROID=/path/to/TERMinator and rerun."
    exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo ""
echo "=== Extracting cryptlib ==="
unzip -q "$CRYPTLIB_ZIP"

echo "=== Converting line endings ==="
find . -type f \( -name "*.c" -o -name "*.h" -o -name "*.sh" -o -name "makefile" -o -name "Makefile" \) | while read -r f; do
    tr -d '\r' < "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done 2>/dev/null || true

echo ""
echo "=== Applying Synchronet patches ==="
PATCHES=(
    "cl-terminal-params.patch"
    "cl-ranlib.patch"
    "cl-endian.patch"
    "cl-zz-country.patch"
    "cl-algorithms.patch"
    "cl-allow-duplicate-ext.patch"
    "cl-macosx-minver.patch"
    "cl-posix-me-gently.patch"
    "cl-PAM-noprompts.patch"
    "cl-zlib.patch"
    "cl-Dynamic-linked-static-lib.patch"
    "cl-SSL-fix.patch"
    "cl-bigger-maxattribute.patch"
    "cl-no-odbc.patch"
    "cl-noasm-defines.patch"
    "cl-bn-noasm64-fix.patch"
    "cl-prefer-ECC.patch"
    "cl-prefer-ECC-harder.patch"
    "cl-clear-GCM-flag.patch"
    "cl-use-ssh-ctr.patch"
    "cl-ssh-list-ctr-modes.patch"
    "cl-no-tpm.patch"
    "cl-no-via-aes.patch"
    "cl-just-use-cc.patch"
    "cl-no-safe-stack.patch"
    "cl-allow-pkcs12.patch"
    "cl-allow-none-auth.patch"
    "cl-poll-not-select.patch"
    "cl-good-sockets.patch"
    "cl-moar-objects.patch"
    "cl-remove-march.patch"
    "cl-server-term-support.patch"
    "cl-add-pubkey-attribute.patch"
    "cl-allow-ssh-auth-retries.patch"
    "cl-fix-ssh-channel-close.patch"
    "cl-vt-lt-2005-always-defined.patch"
    "cl-no-pie.patch"
    "cl-no-testobjs.patch"
    "cl-thats-not-asm.patch"
    "cl-make-channels-work.patch"
    "cl-allow-ssh-2.0-go.patch"
    "cl-read-timeout-every-time.patch"
    "cl-pass-after-pubkey.patch"
    "cl-allow-servercheck-pubkeys.patch"
    "cl-double-delete-fine-on-close.patch"
    "cl-handle-unsupported-pubkey.patch"
    "cl-add-patches-info.patch"
    "cl-fix-shell-exec-types.patch"
    "cl-ssh-eof-half-close.patch"
    "cl-ssh-service-type-for-channel.patch"
    "cl-ssh-sbbs-id-string.patch"
    "cl-channel-select-both.patch"
    "cl-allow-none-auth-svr.patch"
    "cl-quote-cc.patch"
    "cl-dont-validate-va-list.patch"
    "cl-fix-constptrptr.patch"
    "cl-fix-void-ptrs.patch"
    "cl-intptr-t.patch"
    "cl-wrong-string-length.patch"
    "cl-remove-silly-pragmas.patch"
    "cl-size-doesnt-mean-copied.patch"
    "cl-add-psk-flag.patch"
    "cl-no-stdc-flexarray.patch"
    "cl-enable-chacha20.patch"
    "cl-no-session-cache.patch"
    "cl-ssh-ed25519.patch"
    "cl-ssh-ed25519-makefile.patch"
)

for patch in "${PATCHES[@]}"; do
    if [ -f "$PATCHES_DIR/$patch" ]; then
        echo "  Applying: $patch"
        patch -p0 --silent < "$PATCHES_DIR/$patch" 2>/dev/null || echo "    (skipped - may be incompatible)"
    fi
done

if ! grep -q '"ssh-ed25519"' session/ssh2_algo.c || [ ! -f session/ssh2_ed25519.c ] || \
   ! grep -q "ssh2_ed25519.o" makefile; then
    echo "ERROR: Ed25519 SSH host key patch did not apply cleanly."
    exit 1
fi

if ! grep -q "versionStringLength, 2" session/ssh2_id.c; then
    echo "ERROR: SSH-2.0-Go cryptlib patch did not apply cleanly."
    exit 1
fi

if [ -f "$PATCHES_DIR/hashpatch.pl" ]; then
    echo "=== Recording cryptlib patch hash ==="
    perl -i.bak "$PATCHES_DIR/hashpatch.pl" "$PATCHES_DIR" cryptlib.h
else
    echo "ERROR: Missing hashpatch.pl at: $PATCHES_DIR/hashpatch.pl"
    exit 1
fi

sed -i.bak "s/%%MIN_MAC_OSX_VERSION%%/$MACOS_MIN_VERSION/g" tools/ccopts.sh 2>/dev/null || true

mkdir -p "$OUTPUT_DIR/include"
mkdir -p "$OUTPUT_DIR/macos-arm64"
mkdir -p "$OUTPUT_DIR/ios-arm64"
mkdir -p "$OUTPUT_DIR/ios-simulator-arm64"
cp cryptlib.h "$OUTPUT_DIR/include/"

common_cflags() {
    echo "-DNDEBUG -D__UNIX__ -DDATA_LITTLEENDIAN -DNO_ODBC -DNO_PKCS11 -DNO_SYSV_SHAREDMEM -DOSVERSION=5 -DNO_ASM -Wno-error -Wno-implicit-function-declaration -Wno-deprecated-declarations"
}

run_make() {
    local output_subdir=$1
    local log_file="$BUILD_DIR/build-$output_subdir.log"

    if ! make -j4 > "$log_file" 2>&1; then
        echo "  ERROR: build failed. Last log lines:"
        tail -80 "$log_file"
        return 1
    fi

    tail -30 "$log_file"
    if [ -f libcl.a ]; then
        cp libcl.a "$OUTPUT_DIR/$output_subdir/"
        echo "  Built: $OUTPUT_DIR/$output_subdir/libcl.a"
        ls -la "$OUTPUT_DIR/$output_subdir/libcl.a"
        lipo -info "$OUTPUT_DIR/$output_subdir/libcl.a"
    else
        echo "  ERROR: libcl.a not found!"
        return 1
    fi
}

build_for_macos_arm64() {
    echo ""
    echo "=== Building for arm64 (macosx) ==="
    make clean 2>/dev/null || true
    rm -f libcl.a static-obj/*.o 2>/dev/null || true

    local sdk_path
    local cc_real
    local ar
    local ranlib
    local wrapper
    sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
    cc_real="$(xcrun --sdk macosx --find clang)"
    ar="$(xcrun --sdk macosx --find ar)"
    ranlib="$(xcrun --sdk macosx --find ranlib)"
    wrapper="$BUILD_DIR/macos-arm64-cc.sh"

    cat > "$wrapper" << 'WRAPPER_EOF'
#!/bin/bash
CC_REAL="REPLACE_CC"
SDK_PATH="REPLACE_SDK"
MIN_VERSION="REPLACE_MIN_VERSION"

ARGS=()
for arg in "$@"; do
    case "$arg" in
        -mmacosx-version-min=*) ;;
        *) ARGS+=("$arg") ;;
    esac
done

# -DTERMINATOR_SSH_ED25519: Ed25519 SSH host keys (cl-ssh-ed25519.patch), macOS
# only. It has to ride on the compiler: cryptlib's makefile assigns its own
# CFLAGS, so the exported CFLAGS never reaches the compile lines.
exec "$CC_REAL" -arch arm64 -isysroot "$SDK_PATH" -mmacosx-version-min="$MIN_VERSION" -DTERMINATOR_SSH_ED25519 "${ARGS[@]}"
WRAPPER_EOF
    sed -i '' "s|REPLACE_CC|$cc_real|g" "$wrapper"
    sed -i '' "s|REPLACE_SDK|$sdk_path|g" "$wrapper"
    sed -i '' "s|REPLACE_MIN_VERSION|$MACOS_MIN_VERSION|g" "$wrapper"
    chmod +x "$wrapper"

    export CC="$wrapper"
    export AR="$ar"
    export RANLIB="$ranlib"
    export CFLAGS
    CFLAGS="$(common_cflags)"

    echo "  SDK_PATH=$sdk_path"
    echo "  CC=$CC"
    echo "  CFLAGS=$CFLAGS"
    run_make "macos-arm64"
}

build_for_ios_arch() {
    local sdk=$1
    local output_subdir=$2

    echo ""
    echo "=== Building for arm64 ($sdk) ==="
    make clean 2>/dev/null || true
    rm -f libcl.a static-obj/*.o 2>/dev/null || true

    local sdk_path
    local cc_real
    local ar
    local ranlib
    local target_flag
    local wrapper
    sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
    cc_real="$(xcrun --sdk "$sdk" --find clang)"
    ar="$(xcrun --sdk "$sdk" --find ar)"
    ranlib="$(xcrun --sdk "$sdk" --find ranlib)"

    if [ "$sdk" = "iphoneos" ]; then
        target_flag="-target arm64-apple-ios${IOS_MIN_VERSION}"
    else
        target_flag="-target arm64-apple-ios${IOS_MIN_VERSION}-simulator"
    fi
    wrapper="$BUILD_DIR/$output_subdir-cc.sh"

    cat > "$wrapper" << 'WRAPPER_EOF'
#!/bin/bash
CC_REAL="REPLACE_CC"
SDK_PATH="REPLACE_SDK"
TARGET_FLAG="REPLACE_TARGET"

ARGS=()
for arg in "$@"; do
    case "$arg" in
        -mmacosx-version-min=*) ;;
        -fstack-clash-protection) ;;
        *) ARGS+=("$arg") ;;
    esac
done

exec "$CC_REAL" $TARGET_FLAG -isysroot "$SDK_PATH" "${ARGS[@]}"
WRAPPER_EOF
    sed -i '' "s|REPLACE_CC|$cc_real|g" "$wrapper"
    sed -i '' "s|REPLACE_SDK|$sdk_path|g" "$wrapper"
    sed -i '' "s|REPLACE_TARGET|$target_flag|g" "$wrapper"
    chmod +x "$wrapper"

    export CC="$wrapper"
    export AR="$ar"
    export RANLIB="$ranlib"
    export CFLAGS
    CFLAGS="$(common_cflags)"

    echo "  SDK_PATH=$sdk_path"
    echo "  CC=$CC"
    echo "  CFLAGS=$CFLAGS"
    run_make "$output_subdir"
}

build_for_macos_arm64
build_for_ios_arch "iphoneos" "ios-arm64"
build_for_ios_arch "iphonesimulator" "ios-simulator-arm64"

echo ""
echo "=== Build complete ==="
echo "Headers: $OUTPUT_DIR/include/"
echo "macOS: $OUTPUT_DIR/macos-arm64/libcl.a"
echo "iOS Device: $OUTPUT_DIR/ios-arm64/libcl.a"
echo "iOS Simulator: $OUTPUT_DIR/ios-simulator-arm64/libcl.a"
