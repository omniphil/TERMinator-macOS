#!/bin/bash
# embed-trace-host.sh -- Xcode build phase "Embed TRACE host" (TERMinator target, after "Embed APC libraries").
#
# Puts the TRACE sandbox host into the app bundle and signs it:
#   gamesandbox           -> TERMinator.app/Contents/Helpers/gamesandbox
#   libwasmtime.dylib     -> TERMinator.app/Contents/Frameworks/libwasmtime.dylib
#   libwgpu_native.dylib  -> TERMinator.app/Contents/Frameworks/libwgpu_native.dylib   (the GPU for modules; optional)
# Contents/Helpers is Apple's place for a helper tool and Contents/Frameworks for a dylib; codesign and notarization
# treat both as nested code (Contents/Resources is for data, and a Mach-O there trips the seal and the notary).
#
# Where the host comes from, first match wins:
#   vendor/trace/                                     a frozen copy, if you keep one (used as-is)
#   ../TERMinator-Windows/trace/bin-macos-universal/  trace/build_gamesandbox.sh --universal    } used only when newer
#   ../TERMinator-Windows/trace/bin-macos-aarch64/    trace/build_gamesandbox.sh on Apple silicon } than the sources
#   ../TERMinator-Windows/trace/bin-macos-arm64/                                                   } and has $ARCHS
# The GPU library (WebGPU for modules, wgpu-native) comes from ../TERMinator-Windows/trace/third_party/, per arch.
# It is never linked against: gamesandbox dlopen()s it by name, and TraceModules.gpuInstalled tells doors gpu=1 only
# when it is in the bundle, so a build without it just has modules draw on the processor.
#   otherwise: BUILT HERE from ../TERMinator-Windows/trace/host/gamesandbox.c and gpu.c with xcrun clang (no CMake), against the
#   Wasmtime C API downloaded once (sha256-pinned) into ~/Library/Caches/TERMinator-build/. The built host is cached
#   there too, keyed by $ARCHS + $MACOSX_DEPLOYMENT_TARGET, and rebuilt only when gamesandbox.c, trace/include/*.h or
#   this script are newer than it. Network is needed the first time only.
# A host that can't be found or built FAILS the build (a TERMinator without it answers every door wasm=0). To build
# without TRACE on purpose set TRACE_HOST_OPTIONAL=YES (env or build setting); TRACE_HOST_REBUILD=YES forces a rebuild.
#
# Signing: the app's identity (EXPANDED_CODE_SIGN_IDENTITY), hardened runtime, and TERMinator/gamesandbox.entitlements
# on the helper (app-sandbox + inherit, since TERMinator is sandboxed; allow-jit + allow-unsigned-executable-memory
# for Wasmtime). Inside-out: dylib, then helper; Xcode signs the app itself after this phase. A build with no identity
# or "Sign to Run Locally" signs ad hoc without entitlements, so it still runs locally.
#
# Runs with ENABLE_USER_SCRIPT_SANDBOXING = NO (it downloads and writes to ~/Library/Caches) and on every build
# (alwaysOutOfDate); the caching is done here.
set -euo pipefail

WASMTIME_VERSION="v48.0.2"
# sha256 of the release archives wasmtime-v48.0.2-<arch>-macos-c-api.tar.xz (checked 2026-09-18)
wasmtime_sha256() {
  case "$1" in
    aarch64) echo "c4b95346d92168963607f8ac56ef70298aa83b9d2b23af3e801759df3443ed09" ;;
    x86_64)  echo "5fbf2c7700063282000dcefe9d0691ac9e27f2f213746acd56f42d1772cebe4a" ;;
    *) return 1 ;;
  esac
}

SCRIPT_PATH="$SRCROOT/scripts/embed-trace-host.sh"
TRACE_WIN="$SRCROOT/../TERMinator-Windows/trace"
TRACE_SRC="$TRACE_WIN/host/gamesandbox.c"
TRACE_GPU_SRC="$TRACE_WIN/host/gpu.c"
TRACE_INC="$TRACE_WIN/include"
WGPU_DIR="$TRACE_WIN/third_party/wgpu-native-v29.0.1.1"
CACHE_ROOT="${TRACE_BUILD_CACHE:-$HOME/Library/Caches/TERMinator-build}"
DEPLOY_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

is_yes() { case "${1:-}" in 1|YES|yes|Yes|true|TRUE|True) return 0 ;; *) return 1 ;; esac; }

# The app's architectures as clang names (arm64e -> arm64), de-duplicated, sorted
CLANG_ARCHS=()
for a in ${ARCHS:-arm64}; do
  case "$a" in
    arm64|arm64e) a=arm64 ;;
    x86_64|x86_64h) a=x86_64 ;;
    *) echo "error: embed-trace-host.sh: unsupported architecture '$a' in ARCHS" >&2; exit 1 ;;
  esac
  case " ${CLANG_ARCHS[*]:-} " in *" $a "*) ;; *) CLANG_ARCHS+=("$a") ;; esac
done
CLANG_ARCHS=($(printf '%s\n' "${CLANG_ARCHS[@]}" | sort))

# True when the binary $1 exists and none of the sources (gamesandbox.c, trace/include, this script) is newer
newer_than_sources() {
  [ -e "$1" ] || return 1
  [ -z "$(find "$TRACE_SRC" "$TRACE_GPU_SRC" "$TRACE_WIN/host/gpu.h" "$TRACE_INC" "$SCRIPT_PATH" \
          -type f -newer "$1" 2>/dev/null)" ]
}

# True unless this checkout has wgpu-native for every arch we build while the cached host in $1 has no GPU library.
# The wgpu dylibs arrive separately from the sources (a Dropbox sync of TERMinator-Windows/trace/third_party), and
# newer_than_sources only looks at gamesandbox.c, gpu.c, trace/include and this script -- so a host compiled before
# they landed has no -DTRACE_GPU, stays "up to date" for ever, and every build quietly ships modules that draw on the
# processor. That is exactly what happened on 2026-09-20.
gpu_in_sync() {
  local arch wgpu_src
  [ -f "$WGPU_DIR/include/webgpu/webgpu.h" ] || return 0
  for arch in "${CLANG_ARCHS[@]}"; do
    wgpu_src="$WGPU_DIR/lib/macos-$([ "$arch" = arm64 ] && echo aarch64 || echo x86_64)/libwgpu_native.dylib"
    [ -f "$wgpu_src" ] || return 0
  done
  [ -f "$1/libwgpu_native.dylib" ]
}

# True when the Mach-O $1 has every architecture in CLANG_ARCHS
has_archs() {
  local have a
  have=" $(lipo -archs "$1" 2>/dev/null || true) "
  for a in "${CLANG_ARCHS[@]}"; do
    case "$have" in *" $a "*) ;; *) return 1 ;; esac
  done
  return 0
}

# ---------------------------------------------------------------------------------------------------------------
# 1. A prebuilt host
SRC=""
if [ -x "$SRCROOT/vendor/trace/gamesandbox" ] && [ -f "$SRCROOT/vendor/trace/libwasmtime.dylib" ]; then
  SRC="$SRCROOT/vendor/trace"
fi
if [ -z "$SRC" ] && ! is_yes "${TRACE_HOST_REBUILD:-}"; then
  for dir in "$TRACE_WIN/bin-macos-universal" "$TRACE_WIN/bin-macos-aarch64" "$TRACE_WIN/bin-macos-arm64"; do
    if [ -x "$dir/gamesandbox" ] && [ -f "$dir/libwasmtime.dylib" ]; then
      if ! has_archs "$dir/gamesandbox"; then
        echo "note: $dir/gamesandbox lacks one of: ${CLANG_ARCHS[*]} (skipped)"
      elif ! newer_than_sources "$dir/gamesandbox"; then
        echo "note: $dir/gamesandbox is older than the TRACE sources (skipped; building a fresh one)"
      else
        SRC="$dir"
        break
      fi
    fi
  done
fi

# ---------------------------------------------------------------------------------------------------------------
# 2. Otherwise build it (cached outside Dropbox)
BUILT_DIR="$CACHE_ROOT/gamesandbox-$(IFS=-; echo "${CLANG_ARCHS[*]}")-macos$DEPLOY_TARGET"

# fetch_wasmtime <aarch64|x86_64>: make sure $CACHE_ROOT/wasmtime-<ver>-<arch>-macos-c-api is there and complete
fetch_wasmtime() {
  local arch="$1" name dir tmp sum want
  name="wasmtime-${WASMTIME_VERSION}-${arch}-macos-c-api"
  dir="$CACHE_ROOT/$name"
  if [ -f "$dir/lib/libwasmtime.dylib" ] && [ -f "$dir/include/wasm.h" ] && [ -f "$dir/include/wasmtime.h" ] \
     && [ -f "$dir/include/wasi.h" ]; then
    return 0
  fi
  want="$(wasmtime_sha256 "$arch")"
  mkdir -p "$CACHE_ROOT"
  tmp="$(mktemp -d "$CACHE_ROOT/.dl.XXXXXX")"
  echo "Downloading $name.tar.xz (first build only) ..."
  if ! curl -fL --retry 3 --connect-timeout 30 -sS -o "$tmp/$name.tar.xz" \
        "https://github.com/bytecodealliance/wasmtime/releases/download/${WASMTIME_VERSION}/$name.tar.xz"; then
    rm -rf "$tmp"
    echo "error: TRACE: couldn't download $name.tar.xz (no network?)" >&2
    return 1
  fi
  sum="$(shasum -a 256 "$tmp/$name.tar.xz" | awk '{print $1}')"
  if [ "$sum" != "$want" ]; then
    rm -rf "$tmp"
    echo "error: TRACE: $name.tar.xz has sha256 $sum, expected $want" >&2
    return 1
  fi
  tar -xJf "$tmp/$name.tar.xz" -C "$tmp"
  if [ ! -f "$tmp/$name/lib/libwasmtime.dylib" ] || [ ! -f "$tmp/$name/include/wasm.h" ] \
     || [ ! -f "$tmp/$name/include/wasmtime.h" ] || [ ! -f "$tmp/$name/include/wasi.h" ]; then
    rm -rf "$tmp"
    echo "error: TRACE: $name.tar.xz didn't contain lib/libwasmtime.dylib + include/wasm.h" >&2
    return 1
  fi
  rm -rf "$dir"
  mv "$tmp/$name" "$dir"
  rm -rf "$tmp"
  echo "Cached $dir"
}

# build_host: compile gamesandbox for each arch in CLANG_ARCHS, lipo, leave gamesandbox + libwasmtime.dylib in BUILT_DIR.
# Same flags as trace/host/CMakeLists.txt (C11 + extensions, -O2 -Wall -Wextra -Wno-unused-parameter, pthreads,
# rpath @loader_path, no defines on POSIX), plus the rpath the bundle needs (@executable_path/../Frameworks, seen from
# Contents/Helpers).
build_host() {
  local sdk tmp arch wtarch wt deps wgpu_src
  local helpers=() dylibs=() wgpus=() gpu_flags=()
  [ -f "$TRACE_SRC" ] || { echo "error: TRACE: host source not found at $TRACE_SRC" >&2; return 1; }
  sdk="$(xcrun --sdk macosx --show-sdk-path)"
  tmp="$(mktemp -d "$CACHE_ROOT/.build.XXXXXX")"
  for arch in "${CLANG_ARCHS[@]}"; do
    wtarch="$([ "$arch" = arm64 ] && echo aarch64 || echo x86_64)"
    fetch_wasmtime "$wtarch"
    wt="$CACHE_ROOT/wasmtime-${WASMTIME_VERSION}-${wtarch}-macos-c-api"
    # Our own copy of the dylib with install name @rpath/libwasmtime.dylib (the v48.0.2 release already has it; made
    # sure), so the helper records exactly that when it's linked against it.
    cp -f "$wt/lib/libwasmtime.dylib" "$tmp/libwasmtime-$arch.dylib"
    chmod u+w "$tmp/libwasmtime-$arch.dylib"
    install_name_tool -id "@rpath/libwasmtime.dylib" "$tmp/libwasmtime-$arch.dylib"
    # The GPU back end (gpu.c) when this checkout has wgpu-native for this arch: headers only, since the library is
    # opened by name at run time (nothing is linked against it, so a bundle without it still runs)
    gpu_flags=()
    wgpu_src="$WGPU_DIR/lib/macos-$([ "$arch" = arm64 ] && echo aarch64 || echo x86_64)/libwgpu_native.dylib"
    if [ -f "$WGPU_DIR/include/webgpu/webgpu.h" ] && [ -f "$wgpu_src" ]; then
      gpu_flags=(-DTRACE_GPU -I "$WGPU_DIR/include/webgpu")
      cp -f "$wgpu_src" "$tmp/libwgpu_native-$arch.dylib"
      chmod u+w "$tmp/libwgpu_native-$arch.dylib"
      install_name_tool -id "@rpath/libwgpu_native.dylib" "$tmp/libwgpu_native-$arch.dylib"
      wgpus+=("$tmp/libwgpu_native-$arch.dylib")
    else
      echo "note: no wgpu-native for $arch in $WGPU_DIR/lib -- this build has no GPU for modules"
    fi
    echo "Compiling gamesandbox ($arch, macOS $DEPLOY_TARGET)"
    xcrun --sdk macosx clang -arch "$arch" -isysroot "$sdk" -mmacosx-version-min="$DEPLOY_TARGET" \
      -std=gnu11 -O2 -Wall -Wextra -Wno-unused-parameter -pthread \
      -I "$wt/include" -I "$TRACE_INC" ${gpu_flags[@]+"${gpu_flags[@]}"} \
      "$TRACE_SRC" "$TRACE_GPU_SRC" "$tmp/libwasmtime-$arch.dylib" \
      -Wl,-rpath,@loader_path -Wl,-rpath,@executable_path/../Frameworks -Wl,-headerpad_max_install_names \
      -o "$tmp/gamesandbox-$arch"
    helpers+=("$tmp/gamesandbox-$arch")
    dylibs+=("$tmp/libwasmtime-$arch.dylib")
  done
  lipo -create "${helpers[@]}" -output "$tmp/gamesandbox"
  lipo -create "${dylibs[@]}" -output "$tmp/libwasmtime.dylib"
  # The GPU library only when every arch we built has one, so a universal bundle is never half-covered
  if [ "${#wgpus[@]}" -eq "${#CLANG_ARCHS[@]}" ]; then
    lipo -create "${wgpus[@]}" -output "$tmp/libwgpu_native.dylib"
    codesign --force --sign - "$tmp/libwgpu_native.dylib"
  fi
  chmod 755 "$tmp/gamesandbox"
  # Ad hoc for now (arm64 won't run unsigned code); the copy in the bundle is re-signed below.
  codesign --force --sign - "$tmp/libwasmtime.dylib"
  codesign --force --sign - "$tmp/gamesandbox"
  deps="$(otool -L "$tmp/gamesandbox")"
  if ! grep -q "@rpath/libwasmtime.dylib" <<<"$deps"; then
    echo "error: TRACE: the built gamesandbox doesn't link @rpath/libwasmtime.dylib:" >&2
    echo "$deps" >&2
    return 1
  fi
  mkdir -p "$BUILT_DIR"
  rm -f "$BUILT_DIR/gamesandbox" "$BUILT_DIR/libwasmtime.dylib" "$BUILT_DIR/libwgpu_native.dylib"
  mv "$tmp/libwasmtime.dylib" "$BUILT_DIR/libwasmtime.dylib"
  if [ -f "$tmp/libwgpu_native.dylib" ]; then
    mv "$tmp/libwgpu_native.dylib" "$BUILT_DIR/libwgpu_native.dylib"
  fi
  mv "$tmp/gamesandbox" "$BUILT_DIR/gamesandbox"   # last, so a half-finished build never looks current
  rm -rf "$tmp"
  echo "Built TRACE host in $BUILT_DIR"
}

if [ -z "$SRC" ]; then
  if ! is_yes "${TRACE_HOST_REBUILD:-}" && [ -x "$BUILT_DIR/gamesandbox" ] && [ -f "$BUILT_DIR/libwasmtime.dylib" ] \
     && newer_than_sources "$BUILT_DIR/gamesandbox" && has_archs "$BUILT_DIR/gamesandbox" \
     && gpu_in_sync "$BUILT_DIR"; then
    echo "TRACE host up to date in $BUILT_DIR"
  else
    if [ -x "$BUILT_DIR/gamesandbox" ] && ! gpu_in_sync "$BUILT_DIR"; then
      echo "note: the cached TRACE host has no GPU library but wgpu-native is here now -- rebuilding with the GPU"
    fi
    mkdir -p "$CACHE_ROOT"
    # A plain subshell, NOT an if/&&/|| operand: bash switches set -e off inside those.
    set +e
    ( set -euo pipefail; build_host )
    rc=$?
    set -e
    rm -rf "$CACHE_ROOT"/.build.* "$CACHE_ROOT"/.dl.* 2>/dev/null || true
    if [ $rc -ne 0 ]; then
      if is_yes "${TRACE_HOST_OPTIONAL:-}"; then
        echo "warning: TRACE host couldn't be built; TRACE_HOST_OPTIONAL is set, so this app will answer doors wasm=0"
        exit 0
      fi
      echo "error: TRACE host (gamesandbox) couldn't be built -- see the lines above. Without it doors get wasm=0." >&2
      echo "error: fix that, or build without TRACE on purpose with TRACE_HOST_OPTIONAL=YES." >&2
      exit 1
    fi
  fi
  SRC="$BUILT_DIR"
fi
echo "Embedding TRACE host from $SRC"

# ---------------------------------------------------------------------------------------------------------------
# 3. Copy into the bundle and sign (inside-out)
CONTENTS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
HELPERS="$CONTENTS/Helpers"
FRAMEWORKS="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$HELPERS" "$FRAMEWORKS"
# rm first: overwriting a Mach-O that already ran in place (same inode) can leave the kernel's cached signature
# stale, and the next launch gets "Killed: 9".
rm -f "$HELPERS/gamesandbox" "$FRAMEWORKS/libwasmtime.dylib" "$FRAMEWORKS/libwgpu_native.dylib"
cp "$SRC/gamesandbox" "$HELPERS/gamesandbox"
cp "$SRC/libwasmtime.dylib" "$FRAMEWORKS/libwasmtime.dylib"
chmod 755 "$HELPERS/gamesandbox"
chmod 644 "$FRAMEWORKS/libwasmtime.dylib"
# The GPU library, when the host we're shipping came with one. gamesandbox dlopen()s "libwgpu_native.dylib", which
# finds it through the helper's @executable_path/../Frameworks rpath; without it modules just draw on the processor.
if [ -f "$SRC/libwgpu_native.dylib" ]; then
  cp "$SRC/libwgpu_native.dylib" "$FRAMEWORKS/libwgpu_native.dylib"
  chmod 644 "$FRAMEWORKS/libwgpu_native.dylib"
  install_name_tool -id "@rpath/libwgpu_native.dylib" "$FRAMEWORKS/libwgpu_native.dylib"
fi

# The dylib by @rpath, whatever install name it was built with (already so for a host built here; harmless twice)
old_id="$(otool -D "$FRAMEWORKS/libwasmtime.dylib" | sed -n '2p')"
install_name_tool -id "@rpath/libwasmtime.dylib" "$FRAMEWORKS/libwasmtime.dylib"
if [ -n "$old_id" ] && [ "$old_id" != "@rpath/libwasmtime.dylib" ]; then
  install_name_tool -change "$old_id" "@rpath/libwasmtime.dylib" "$HELPERS/gamesandbox" || true
fi
# Find it in Contents/Frameworks (a host from build_gamesandbox.sh only has @loader_path). Load commands captured
# first: under pipefail, `otool -l | grep -q` can fail on otool's SIGPIPE when grep quits early, and a second
# -add_rpath is an error.
load_cmds="$(otool -l "$HELPERS/gamesandbox")"
if ! grep -q "@executable_path/../Frameworks" <<<"$load_cmds"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$HELPERS/gamesandbox"
fi

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
  ts="--timestamp=none"
  if [ "${CONFIGURATION:-}" = "Release" ]; then ts="--timestamp"; fi
  if [ -f "$FRAMEWORKS/libwgpu_native.dylib" ]; then
    codesign --force --options runtime $ts --sign "$IDENTITY" "$FRAMEWORKS/libwgpu_native.dylib"
  fi
  codesign --force --options runtime $ts --sign "$IDENTITY" "$FRAMEWORKS/libwasmtime.dylib"
  codesign --force --options runtime $ts --sign "$IDENTITY" \
           --entitlements "$SRCROOT/TERMinator/gamesandbox.entitlements" "$HELPERS/gamesandbox"
else
  # Ad hoc ("Sign to Run Locally" or none): no entitlements on the helper. A child of a sandboxed app inherits the
  # sandbox anyway, and an unsigned app isn't sandboxed at all -- where a child carrying inherit is killed at launch.
  if [ -f "$FRAMEWORKS/libwgpu_native.dylib" ]; then
    codesign --force --sign - "$FRAMEWORKS/libwgpu_native.dylib"
  fi
  codesign --force --sign - "$FRAMEWORKS/libwasmtime.dylib"
  codesign --force --sign - "$HELPERS/gamesandbox"
fi
if [ -f "$FRAMEWORKS/libwgpu_native.dylib" ]; then
  codesign --verify --strict "$FRAMEWORKS/libwgpu_native.dylib"
fi
codesign --verify --strict "$FRAMEWORKS/libwasmtime.dylib"
codesign --verify --strict "$HELPERS/gamesandbox"
echo "TRACE host embedded: $HELPERS/gamesandbox ($(lipo -archs "$HELPERS/gamesandbox"))"
