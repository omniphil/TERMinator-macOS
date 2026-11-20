# macOS terminal-engine migration — 2026-09-04

macOS now runs SyncTERM's **real `cterm.c`** instead of the hand-rolled ANSI/Sixel
parser it had since the beginning. This is the same swap iOS made on 2026-07-16,
which is **shipping in the App Store today** — so the engine itself is proven on
Apple, not experimental.

## Why

PETSCII (C64/C128) lives entirely inside `cterm.c`'s `CTERM_EMULATION_PETASCII`
branch — the colour-code table, the 0x0E/0x8E case switch, reverse-video. There
was nowhere to put it in the old parser short of reimplementing it, so the
migration is the prerequisite for PETSCII on macOS. It also brings proper Sixel
(aspect ratio, transparency masks, palette registers), which the old parser
ignored, and puts macOS on the identical emulator to Android, Windows and Linux.

## ⏪ HOW TO BACK IT OUT — one line

`TERMinator/Bridge/cterm_mode.h`:

    #define USE_REAL_CTERM 1     ->     #define USE_REAL_CTERM 0

Rebuild. macOS behaves exactly as it did before 2026-09-04. **Nothing was
deleted** — the legacy parser is still in `syncterm_stubs.c`, just compiled out.
No Xcode project change is needed to roll back: `cterm.c` compiles to an empty
translation unit when the flag is 0.

## What changed — every edit is marked `macOS MIGRATION`

Grep the tree for `macOS MIGRATION` to find all of it.

| # | file | change | reverted by the flag? |
|---|------|--------|----------------------|
| 1 | `Bridge/cterm_mode.h` | **NEW.** The `USE_REAL_CTERM` switch. | n/a — it *is* the switch |
| 2 | `Bridge/conio/cterm.c` | **NEW.** Copy of the shared engine + 3 Apple patches. | yes — whole file is `#if USE_REAL_CTERM` |
| 3 | `Bridge/syncterm_stubs.c` | Legacy parser wrapped in `#if !USE_REAL_CTERM`, plus an `#else` no-op `cterm_reset_ansi_state()` shim. | yes |
| 4 | `Bridge/macos_stubs.c` | Added `ciolib_cputs`, `ciolib_map_rgb`, `ciolib_replace_font`. | no — harmless either way, never called by the legacy parser |
| 5 | `Bridge/syncterm_macos.c` | `#include "cterm_mode.h"`. | no — include only |
| 6 | `TERMinator.xcodeproj` | `conio/cterm.c` added to the target (ids `AA1000…0007`/`0008`). | no — file is inert when the flag is 0 |

### The three Apple patches inside `cterm.c`

1. **Build gate** — whole file wrapped in `#if USE_REAL_CTERM`, with a non-empty
   `#else` typedef so the compiler doesn't warn about an empty translation unit.
2. **OSC 800 (TAP+ audio)** — an `#elif defined(__APPLE__)` branch routing to
   `ios_audio_command()`, replacing what the legacy parser's `dispatch_osc()`
   did. macOS uses the iOS symbol name for this, so the branch is byte-identical
   to the shipping iOS one.
3. **Bell** — five `#ifdef __unix__` blocks widened to
   `#if defined(__unix__) || defined(__APPLE__)`.
   ⚠️ The `#ifdef __unix__` around `#include <xpsem.h>` was deliberately **left
   alone**, matching iOS: `__unix__` is defined by Apple clang, so widening it
   would change nothing and only make the two Apple copies harder to diff.

## ⚠️ `Bridge/conio/cterm.c` is a COPY, not the shared source

Android, Windows and Linux all compile `TERMinator/src/conio/cterm.c` directly.
The two Apple targets each keep a local copy because they need the patches above.
**When the master changes, re-copy and re-apply the patches — do not hand-merge.**

This copy was taken from the master on 2026-09-04, so it is current. iOS's copy
was taken 2026-07-16 and had already drifted: it is missing the
`ciolib_clear_pixel_rect()` call from the 2026-08-17 sixel partial-erase fix,
which is why iOS still ghosts images on `ESC[1J` / `ESC[1K`. The macOS copy has
it. (That drift is exactly the failure mode this warning exists to prevent.)

## PETSCII — wired 2026-09-04, tagged `macOS PETSCII 2026-09-04`

Grep for that tag. This is a **separate** set of edits from the migration above:
they depend on it, but they are not reverted by `USE_REAL_CTERM 0` (they would
simply be inert, since the legacy parser has no PETASCII branch).

| file | change |
|---|---|
| `Bridge/macos_ciolib.c` `.h` | `vmode_override` state; `current_vmode()` honours it; `textmode()` learns the Commodore geometries; cleanup resets it; new `apply_mode_palette` / `set_video_mode` / `get_video_mode` / `mode_no_blink` / `get_mode_char_height` |
| `Bridge/syncterm_macos.c` | `g_emulation` (all three `cterm_init` calls now use it); `recreate_cterm_locked()`; screen modes 9/10/11 → PETASCII + `C64_40X25`/`C128_*`; Commodore starting font + `altfont[0]`; `resolved_font_id()`; 8x8 font-slot preference; `blink_bit` in the screen packer; `native_mode_no_blink()` / `native_get_display_aspect()` |
| `Bridge/native_bridge.h` | declares the two new exports |
| `Models/BBSEntry.swift` | `modeC64`/`modeC128_40`/`modeC128_80` (9/10/11), `isCommodore`, `displayAspect`, `commodoreFontName` |
| `ViewModels/TerminalViewModel.swift` | publishes `displayAspect` + `petsciiMode`; installs the Commodore font on connect; stops `loadFontBitmap()` re-applying the saved font in a Commodore mode |
| `Views/TerminalMetalView.swift` | forced display aspect in the render quad; note on why the blink branch is never taken in a Commodore mode |
| `Views/TerminalView.swift` | `cellSizeInPoints()` uses the identical aspect algorithm so clicks land on the right cell |

### Three traps this wiring exists to avoid

1. **`cterm_write` RESTORES the font before returning**, so the PETSCII 0x0E/0x8E
   case switch is already undone by the time we poll. `resolved_font_id()` reads
   `cterm->altfont[0]`, not the live ciolib font. Anything that reports or loads
   the font must go through it.
2. **Attribute bit 7 is background-brightness, not blink**, in the Commodore
   modes. The packer strips it there; the renderer's blink branch is therefore
   never entered on a PETSCII screen. Do not "restore" the bit.
3. **A forced aspect makes the two axis scales differ.** The renderer and
   `cellSizeInPoints()` must use the same algorithm or clicks drift down the
   screen. Both were changed together; with `displayAspect` nil both are
   arithmetically identical to the uniform `min()` scale they replaced.

### Deliberately NOT done

No PETSCII **keyboard** mapping (C= colour bank, cursor/HOME/CLR/INST codes).
iOS does not have one either — only Windows does — so this matches the shipping
Apple client. Typing sends plain ASCII, which boards accept; the colour and
cursor key codes are what is missing.

## Status

**Source-complete, NOT BUILT HERE** — there is no Mac on the machine this was
written on. The engine migration was reported as building; the PETSCII wiring on
top of it has not been compiled. Everything was verified statically:
every `#include` in the new files resolves against the target's
`HEADER_SEARCH_PATHS`, the project file validates (184 build files, 0 dangling
`fileRef`s, 0 undeclared phase entries), and the generated `cterm.c` is
code-identical to the shipping iOS copy apart from the sixel fix noted above.
