#ifndef CTERM_MODE_H
#define CTERM_MODE_H

/*
 * ============================================================================
 * macOS TERMINAL-ENGINE SELECTOR  —  ONE-LINE ROLLBACK LIVES HERE
 * ============================================================================
 *
 *   USE_REAL_CTERM 1  -> SyncTERM's real cterm.c engine (Bridge/conio/cterm.c).
 *                        Full ANSI + proper Sixel (aspect ratio, transparency
 *                        masks, palette registers) and — the reason this
 *                        migration happened — the PETASCII branch that makes
 *                        C64/C128 PETSCII possible at all. Byte-for-byte the
 *                        same emulator that runs on Android, Windows and Linux,
 *                        and the same one shipping in the iOS App Store build.
 *
 *   USE_REAL_CTERM 0  -> Fall back to the legacy hand-rolled ANSI/Sixel parser
 *                        in syncterm_stubs.c, exactly as macOS behaved before
 *                        2026-09-04. PETSCII is unavailable in this mode.
 *
 * TO BACK THE WHOLE MIGRATION OUT: change the 1 below to a 0 and rebuild.
 * Nothing else has to be touched — the legacy parser was left in place, not
 * deleted, and every migration edit is guarded by this flag. See
 * MIGRATION_CTERM.md next to the Xcode project for the full change list.
 *
 * The flag is honored in three places that must stay in sync:
 *   - Bridge/conio/cterm.c     (whole file compiles only when 1)
 *   - Bridge/syncterm_stubs.c  (legacy parser compiles only when 0)
 *   - Bridge/syncterm_macos.c  (includes this header; its BEL scan is already
 *                               unconditional, so it needs no #if of its own)
 */
#define USE_REAL_CTERM 1

#endif /* CTERM_MODE_H */
