# Rebuild cryptlib (libcl.a) for macOS

## Why

The SSH identifier string validation in cryptlib rejects `SSH-2.0-Go`, which is sent by Go-based SSH proxies used by many BBSes. The fix lowers the minimum software version string length from 3 to 2 characters in the affected checks and annotations in `session/ssh2_id.c`.

## What's already done

- `cryptlib.h` in `TERMinator-macOS/TERMinator/Bridge/cryptlib/include/` has been updated
- The source code in `TERMinator/3rdp/src/cl/session/ssh2_id.c` is already patched
- The patch file `TERMinator/3rdp/build/cl-allow-ssh-2.0-go.patch` has been updated with the complete fix

## What needs to be done (on a Mac with Xcode)

You need to rebuild `libcl.a` for three targets from the patched source at `TERMinator/3rdp/src/cl/`:

### 1. macOS arm64 (Apple Silicon native)

```bash
cd /path/to/TERMinator/3rdp/src/cl

make clean

# Build for macOS arm64
make CC="clang -arch arm64 -mmacosx-version-min=13.0" \
     CFLAGS="-c -D__UNIX__ -DNDEBUG -I. -O2" \
     LDFLAGS=""
```

Then copy the output:
```bash
cp libcl.a /path/to/TERMinator-macOS/TERMinator/Bridge/cryptlib/macos-arm64/libcl.a
```

### 2. iOS arm64 (device) - also used by macOS project

```bash
cd /path/to/TERMinator/3rdp/src/cl

make clean

# Build for iOS arm64
make CC="xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -fembed-bitcode" \
     CFLAGS="-c -DNDEBUG -I. -O2" \
     LDFLAGS="CROSSCOMPILE=1"
```

Then copy the output:
```bash
cp libcl.a /path/to/TERMinator-macOS/TERMinator/Bridge/cryptlib/ios-arm64/libcl.a
```

### 3. iOS Simulator arm64 (Apple Silicon Mac simulator)

```bash
cd /path/to/TERMinator/3rdp/src/cl

make clean

# Build for iOS Simulator arm64
make CC="xcrun -sdk iphonesimulator clang -arch arm64 -miphonesimulator-version-min=15.0" \
     CFLAGS="-c -DNDEBUG -I. -O2" \
     LDFLAGS="CROSSCOMPILE=1"
```

Then copy the output:
```bash
cp libcl.a /path/to/TERMinator-macOS/TERMinator/Bridge/cryptlib/ios-simulator-arm64/libcl.a
```

### Alternative: Use the SyncTERM build system

If the above doesn't work cleanly, you can use the SyncTERM build system which handles all the patches automatically:

```bash
cd /path/to/TERMinator/3rdp/build
make cryptlib
```

This unzips stock cryptlib from `dist/cryptlib.zip`, applies all patches (including the updated `cl-allow-ssh-2.0-go.patch`), and builds. You'll then need to copy the resulting `libcl.a` to the macOS project.

## Files changed in this fix

| File | Change |
|------|--------|
| `TERMinator/3rdp/src/cl/session/ssh2_id.c` | Affected checks and annotations: min versionStringLength 3 -> 2 |
| `TERMinator/3rdp/src/cl/cryptlib.h` | Added CRYPTLIB_PATCHES define |
| `TERMinator/3rdp/build/cl-allow-ssh-2.0-go.patch` | Updated with the complete SSH-2.0-Go fix |
| `TERMinator-macOS/TERMinator/Bridge/cryptlib/include/cryptlib.h` | Updated to match source |

## Verification

After rebuilding, connect to a BBS that uses a Go SSH proxy. The `SSH-2.0-Go` identifier should no longer be rejected.
