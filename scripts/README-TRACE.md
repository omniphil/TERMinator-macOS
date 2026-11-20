# TRACE on macOS: building and bundling the sandbox host

TRACE (TERMinator Render And Compute Engine) runs a door's WebAssembly module in a separate process, `gamesandbox`
(Wasmtime 48). The app side is Swift (`Services/EngineModuleHost.swift`, `TraceSessionManager.swift`,
`TraceModules.swift`, `TraceAudioStream.swift`, `PhysicalKeys.swift`, `Views/EngineHostLayer.swift`,
`Bridge/apc/trace_bridge.c`); the host is shared C in `TERMinator-Windows/trace/host/gamesandbox.c`. Spec:
`TERMinator-Windows/PORT_TO_MAC_LINUX.md` §12.22–12.26.

## 1. Build the app -- that's all

A normal Xcode build (or `scripts/build-dmg.sh`) does everything. The target's last build phase, **Embed TRACE host**
(`scripts/embed-trace-host.sh`, runs every build, script sandboxing off):

1. uses a prebuilt host if there is one: `vendor/trace/` (a frozen copy, used as-is), else
   `../TERMinator-Windows/trace/bin-macos-universal/`, `bin-macos-aarch64/`, `bin-macos-arm64/` -- those only when
   they're newer than the sources and cover the target's `ARCHS`;
2. otherwise **builds it**: downloads the Wasmtime v48.0.2 C API for each arch in `ARCHS` (arm64 only today) into
   `~/Library/Caches/TERMinator-build/wasmtime-v48.0.2-<arch>-macos-c-api/` (sha256-pinned, first build only -- needs
   network then), compiles `TERMinator-Windows/trace/host/gamesandbox.c` with `xcrun clang` (no CMake; same flags as
   `trace/host/CMakeLists.txt`, `MACOSX_DEPLOYMENT_TARGET` from Xcode) and caches the result in
   `~/Library/Caches/TERMinator-build/gamesandbox-<archs>-macos<target>/`. It rebuilds only when `gamesandbox.c`,
   `trace/include/*.h` or the script change;
3. copies `gamesandbox` -> `TERMinator.app/Contents/Helpers/gamesandbox` and `libwasmtime.dylib` ->
   `TERMinator.app/Contents/Frameworks/libwasmtime.dylib` (install name `@rpath/libwasmtime.dylib`, helper rpath
   `@executable_path/../Frameworks`), and signs them inside-out with the app's identity: hardened runtime, the helper
   with `TERMinator/gamesandbox.entitlements`. "Sign to Run Locally" signs both ad hoc without entitlements.

## 1a. The GPU for modules (optional)

A module can draw on the graphics card through WebGPU (`trace/host/gpu.c`, spec §12.49 and §12.52). The build phase
also compiles `gpu.c` and, when `TERMinator-Windows/trace/third_party/wgpu-native-v29.0.1.1/lib/macos-<arch>/` has
`libwgpu_native.dylib`, copies it to `TERMinator.app/Contents/Frameworks/libwgpu_native.dylib` and signs it with the
rest.

It is **never linked against**: `gpu.c` `dlopen`s it by name and resolves its functions through `dlsym`. That is
deliberate -- a missing linked library would stop `gamesandbox` before `main` and take TRACE down with it, so a
bundle without the dylib simply has no GPU and modules draw on the processor. `TraceModules.gpuInstalled` looks for
exactly that file and only then tells doors `gpu=1`.

To check it on the Mac:

```sh
ls TERMinator.app/Contents/Frameworks/libwgpu_native.dylib     # there = doors get gpu=1
otool -L TERMinator.app/Contents/Helpers/gamesandbox           # must NOT list wgpu
```

If the host can't be found or built, **the build fails** (an app without it answers every door's `TRACE;Query` with
`wasm=0`). To build without TRACE on purpose: `TRACE_HOST_OPTIONAL=YES` (environment or build setting, e.g.
`xcodebuild ... TRACE_HOST_OPTIONAL=YES`). `TRACE_HOST_REBUILD=YES` forces a fresh build; deleting
`~/Library/Caches/TERMinator-build` starts over completely. `build-dmg.sh` also checks the exported app's helper still
has its entitlements and hardened runtime after `-exportArchive`, and re-signs it inside-out if not.

End users just install the DMG: the helper and dylib ship inside `TERMinator.app`.

## 2. Building the host by hand (optional)

For a universal build or the headless probe, on the Mac with Xcode command line tools and CMake (`brew install cmake`):

```sh
cd ~/Dropbox/Coding/TERMinator-Windows/trace
./build_gamesandbox.sh            # Apple silicon -> trace/bin-macos-aarch64/
# or: ./build_gamesandbox.sh --universal   -> trace/bin-macos-universal/
```

It downloads the Wasmtime C API into `trace/third_party/` if missing and leaves `gamesandbox`, `gamesandbox_probe`
and `libwasmtime.dylib` (ad hoc signed, dylib by `@rpath`) in the output folder, which the Xcode phase then prefers
(while it's newer than the sources). Quick check without the app: `bin-macos-aarch64/gamesandbox_probe`
(see `trace/tools/gamesandbox_probe.c`).

Why Helpers + Frameworks and not `Contents/Resources/trace/`: codesign and notarization treat `Helpers` and
`Frameworks` as nested code and sign/verify them; a Mach-O under `Resources` is sealed as a data file, which breaks
the helper's own signature and entitlements and fails notarization.

## 3. Check it on the Mac

```sh
ls TERMinator.app/Contents/Helpers TERMinator.app/Contents/Frameworks        # gamesandbox, libwasmtime.dylib
codesign -dv --entitlements - TERMinator.app/Contents/Helpers/gamesandbox   # app-sandbox, inherit, allow-jit, ...
codesign --verify --deep --strict TERMinator.app
otool -L TERMinator.app/Contents/Helpers/gamesandbox                         # @rpath/libwasmtime.dylib
```

At launch the app logs `TRACE helper: <path>` (or `TRACE helper missing: ...`) to Console.app, subsystem
`com.terminator.macos`, category `TRACE`:
`log show --last 5m --predicate 'subsystem == "com.terminator.macos" AND category == "TRACE"'`.

Then connect to a TRACE door (Fractals, Doom). If a module won't start the door gets `Closed;...;error=start-failed`
and Console.app shows it under subsystem `com.terminator.macos`, category `TRACE`. A helper killed at launch with
"sandbox" in the crash report is the entitlements (inherit needs a sandboxed parent; see the entitlements file).

## Where things live at run time

- Frame buffers: the app's temp dir (`$TMPDIR/TRACE-<pid>-<uuid>.frame`, deleted when the module stops)
- Module/asset cache: `~/Library/Containers/com.terminator.macos/Data/Library/Application Support/TERMinator/trace/cache/`
- Module settings: `.../Application Support/TERMinator/trace/store/<id>.bin`
