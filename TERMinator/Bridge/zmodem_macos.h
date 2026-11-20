/**
 * ZMODEM iOS Bridge Header
 *
 * Public API for ZMODEM file transfers on iOS
 */

#ifndef _ZMODEM_IOS_H_
#define _ZMODEM_IOS_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Transfer states (matches Swift TransferState enum)
#define ZMODEM_STATE_IDLE       0
#define ZMODEM_STATE_RECEIVING  1
#define ZMODEM_STATE_SENDING    2
#define ZMODEM_STATE_COMPLETE   3
#define ZMODEM_STATE_ERROR      4
#define ZMODEM_STATE_CANCELLED  5

/**
 * Initialize the ZMODEM transfer system
 * Returns: 1 on success, 0 on failure
 */
int zmodem_macos_init(void);

/**
 * Set download directory for received files
 */
void zmodem_macos_set_download_dir(const char* dir);

/**
 * Receive files via ZMODEM
 * Returns: number of files received, or negative on error
 */
int zmodem_macos_receive(void);

/**
 * Send a file via ZMODEM
 * Returns: 0 on success, negative on error
 */
int zmodem_macos_send(const char* file_path);

/**
 * Send multiple files via ZMODEM in a single batch session.
 * @param paths Array of file paths
 * @param count Number of files
 * Returns: number of files sent (>=0) on success, negative on error
 */
int zmodem_macos_send_batch(const char* const* paths, int count);

/**
 * Transfer > ZMODEM 8K Blocks: non-zero lets uploads grow to 8K subpackets
 * (applied when the next ZMODEM session begins). Downloads are unaffected.
 */
void zmodem_macos_set_8k(int enable);

/** Largest subpacket received in this transfer (downloads: the board's block size). */
unsigned zmodem_macos_largest_rx_block(void);

/**
 * Get the current file index / total for a batch send.
 * Values are 1-based; total 0/1 indicates a single-file transfer.
 */
void zmodem_macos_get_file_index(int32_t *current, int32_t *total);

/**
 * Receive one or more files via X/YMODEM.
 *
 * save_path is the full destination path and is REQUIRED for XMODEM — the
 * protocol carries no filename. Pass NULL for YMODEM, which takes the name from
 * its header block and writes into the download directory.
 *
 * mode is the sbbs3/sexyz.h bit set (XMODEM or YMODEM, optionally | CRC |
 * GMODE, plus XMODEM_128B to pin 128-byte blocks).
 *
 * Returns: number of files received, or negative on error
 */
int xmodem_macos_receive(const char* save_path, int mode);

/**
 * Send one file via X/YMODEM. Single file only — the boards that need
 * X/YMODEM at all do not offer batch uploads.
 * Returns: 0 on success, negative on error
 */
int xmodem_macos_send(const char* file_path, int mode);

/**
 * Cancel current transfer
 */
void zmodem_macos_cancel(void);

/**
 * Get current transfer state
 * Returns: ZMODEM_STATE_* constant
 */
int zmodem_macos_get_state(void);

/**
 * Get transfer progress
 * @param transferred Output: bytes transferred so far
 * @param total Output: total bytes to transfer
 */
void zmodem_macos_get_progress(int64_t *transferred, int64_t *total);

/**
 * Get current file name being transferred
 * Returns: pointer to internal buffer (copy immediately if needed)
 */
const char* zmodem_macos_get_filename(void);

/**
 * Get last error message
 * Returns: pointer to internal buffer
 */
const char* zmodem_macos_get_error(void);

/**
 * Pre-seed the recv buffer with already-telnet-parsed ZRINIT data.
 * Must be called before zmodem_macos_send() to inject captured ZRINIT.
 */
void zmodem_macos_preseed_recv_buffer(const unsigned char *data, int len);

/**
 * Reset transfer state to idle
 */
void zmodem_macos_reset(void);

/**
 * Drain protocol status lines produced since the last call. Each line is a
 * severity char ('I', 'W', 'E') followed by the message, separated by
 * '\n'. Returns bytes written. Lines are handed out once, so polling
 * repeatedly never repeats a line.
 */
int zmodem_macos_get_log(char* buffer, int bufferLen);

/**
 * Discard pending status lines, so a new transfer starts with a clean feed.
 */
void zmodem_macos_clear_log(void);

/**
 * Cleanup transfer system
 */
void zmodem_macos_cleanup(void);

#ifdef __cplusplus
}
#endif

#endif /* _ZMODEM_IOS_H_ */
