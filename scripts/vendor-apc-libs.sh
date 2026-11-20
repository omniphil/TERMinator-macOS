#!/usr/bin/env bash
#
# vendor-apc-libs.sh — Copy libsndfile and libjxl (plus every non-system library they pull in) from Homebrew into
# vendor/apc-libs/, rewritten to load from beside each other, for the SyncTERM APC port (Bridge/apc/).
#
# Usage (on the Mac, once, and again after a Homebrew upgrade you want to ship):
#   brew install libsndfile jpeg-xl
#   ./scripts/vendor-apc-libs.sh
#
# The "Embed APC libraries" build phase copies vendor/apc-libs/*.dylib into TERMinator.app/Contents/Frameworks and
# signs each with the app's identity (hardened runtime + library validation need the same Team ID). The C code
# dlopen()s them from there:
#   libsndfile.1.dylib     apc_sndfile.c  (A;Load / A;LoadBlob, Q;libsndfile)
#   libjxl.dylib           apc_image.c    (C;DrawJXL / C;LoadJXL, Q;JXL)
#   libjxl_threads.dylib   apc_image.c    (optional, multithreaded decode)
# Both features are optional at runtime: with vendor/apc-libs/ empty the app builds and runs, and doors are simply
# told there is no audio / no JPEG XL.
#
# ⚠️ Homebrew bottles are built for the macOS they were poured on. Their LC_BUILD_VERSION minos can be newer than
# the app's deployment target (14.0); on an older macOS the dlopen then fails and the feature is quietly off.
# The script prints each library's minos so that's visible before shipping.
#
# arm64 only, like the app (ARCHS = arm64; cryptlib is arm64-only).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/vendor/apc-libs"
BREW="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"

# Entry libraries: <file name the app dlopens> <Homebrew path>
ENTRIES=(
  "libsndfile.1.dylib|$BREW/opt/libsndfile/lib/libsndfile.1.dylib"
  "libjxl.dylib|$BREW/opt/jpeg-xl/lib/libjxl.dylib"
  "libjxl_threads.dylib|$BREW/opt/jpeg-xl/lib/libjxl_threads.dylib"
)

rm -rf "$OUT"
mkdir -p "$OUT"

# Queue of "<name in OUT>|<source path>". macOS's /bin/bash is 3.2: no associative arrays, so `seen` is a
# space-separated list.
queue=("${ENTRIES[@]}")
seen=" "

is_system() {
  case "$1" in
    /usr/lib/*|/System/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Resolves @rpath / @loader_path references against the source library's directory and Homebrew's lib dir
resolve_dep() {
  local dep="$1" srcdir="$2" name
  case "$dep" in
    @rpath/*|@loader_path/*|@executable_path/*)
      name="${dep##*/}"
      for dir in "$srcdir" "$BREW/lib"; do
        if [[ -e "$dir/$name" ]]; then
          echo "$dir/$name"
          return
        fi
      done
      echo ""
      ;;
    *) echo "$dep" ;;
  esac
}

while ((${#queue[@]})); do
  item="${queue[0]}"
  queue=("${queue[@]:1}")
  name="${item%%|*}"
  src="${item#*|}"
  [[ "$seen" == *" $name "* ]] && continue
  seen="$seen$name "

  if [[ ! -e "$src" ]]; then
    echo "missing: $src (brew install libsndfile jpeg-xl?)" >&2
    exit 1
  fi
  real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$src")"
  cp "$real" "$OUT/$name"
  chmod u+w "$OUT/$name"
  install_name_tool -id "@rpath/$name" "$OUT/$name"

  srcdir="$(dirname "$real")"
  # otool -L: first line is the file, then the install name (for a dylib), then dependencies
  while read -r dep; do
    [[ -z "$dep" ]] && continue
    is_system "$dep" && continue
    depname="${dep##*/}"
    [[ "$depname" == "$name" ]] && continue   # its own install name
    resolved="$(resolve_dep "$dep" "$srcdir")"
    if [[ -z "$resolved" ]]; then
      echo "can't resolve $dep (needed by $name)" >&2
      exit 1
    fi
    install_name_tool -change "$dep" "@loader_path/$depname" "$OUT/$name"
    queue+=("$depname|$resolved")
  done < <(otool -L "$OUT/$name" | tail -n +2 | awk '{print $1}')

  # Homebrew's own absolute rpaths would point outside the bundle
  while read -r rp; do
    [[ -n "$rp" ]] && install_name_tool -delete_rpath "$rp" "$OUT/$name" 2>/dev/null || true
  done < <(otool -l "$OUT/$name" | awk '/LC_RPATH/{getline; getline; print $2}')

  # install_name_tool invalidates Homebrew's ad-hoc signature; the build phase re-signs with the app identity
  codesign --remove-signature "$OUT/$name" 2>/dev/null || true
done

echo
echo "Vendored into $OUT:"
for f in "$OUT"/*.dylib; do
  minos="$(otool -l "$f" | awk '/LC_BUILD_VERSION/{found=1} found && /minos/{print $2; exit}')"
  arch="$(lipo -archs "$f" 2>/dev/null || echo '?')"
  printf '  %-32s minos %-6s %s\n' "$(basename "$f")" "${minos:-?}" "$arch"
done
echo
echo "Non-system dependencies left pointing outside vendor/apc-libs (should be none):"
otool -L "$OUT"/*.dylib | awk '/^\t/ && $1 !~ /^(\/usr\/lib|\/System|@loader_path|@rpath)/ {print "  " $1}' | sort -u
