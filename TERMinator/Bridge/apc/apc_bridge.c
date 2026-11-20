/*
 * apc_bridge.c -- SyncTERM's APC handler (ESC _ SyncTERM:... ST) for the macOS bridge.
 *
 * Ported 2026-09-16 from the Windows client (TERMinator-Windows/native/apc_bridge.c, itself a port of
 * upstream SyncTERM's src/syncterm/term.c apc_handler). Windows is the master: keep the two in step.
 *
 * cterm passes every APC string to cterm->apc_handler, which this build never installed, so all of these
 * used to be dropped:
 *   C;S / C;L                  store base64 data into / list the board's cache directory (name<TAB>md5)
 *   C;Load|Draw PPM|JXL(+Blob), C;LoadPBM(+Blob), P;Copy / P;Paste    pixel images
 *   Q;JXL                      answered only when libjxl loads: any reply, even 0, tells doors this is
 *                              SyncTERM, which changes how they size sixel
 *   A;* and Q;libsndfile*      audio (apc_audio.c)
 * Images draw into macos_ciolib's sixel pixel buffer, so the app shows them exactly like sixel.
 * Not ported: C;SetFont, SyncTERM:VER, and copying the text layer in P;Copy (only drawn pixels copy).
 *
 * Everything runs inside cterm_write() under syncterm_macos.c's g_lock, except the setters at the bottom,
 * which the app calls before connecting, and native_apc_audio_pull (the audio render thread, which only
 * touches the mixer and its own lock).
 *
 * Differences from Windows: POSIX file calls on UTF-8 paths (no wide-char conversion), glob() for C;L as
 * upstream does, and a lexical cache-path check -- a file being stored doesn't exist yet, which rules out
 * realpath(), so ".." segments and absolute paths are refused before joining onto the canonical root.
 */

#include <errno.h>
#include <glob.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/types.h>

#include "macos_ciolib.h"
#include "conn.h"
#include "cterm.h"
#include "ciolib.h"
#include "genwrap.h"
#include "base64.h"
#include "xp_md5.h"
#include "native_bridge.h"

#include "apc_bridge.h"
#include "osc_ext.h"
#include "apc_audio.h"
#include "apc_image.h"
#include "apc_mixer.h"
#include "trace_bridge.h"  /* TRACE: TERMinator Render And Compute Engine escapes */
#include "wm_bridge.h"     /* Rainwire's window protocol (Rainwire:WM;...) */
#include "pic_bridge.h"    /* Rainwire's pictures (TERMinator:Pic;...) */
#include "ui_bridge.h"     /* Rainwire's menus drawn by the app (Rainwire:UI;...), 1.1.6 */

#define APC_PATH_MAX     1024
#define APC_MAX_DIM      8192
#define APC_BLIT_FLIP_X  1
#define APC_BLIT_FLIP_Y  2
#define STORE_MEMO_COUNT 4

enum image_type {
	IMAGE_PPM,
	IMAGE_JXL
};

static char                  g_cache_root[APC_PATH_MAX];   /* UTF-8, canonical, trailing '/'; "" = none */
static struct ciolib_pixels *pixmap_buffer[2];
static struct ciolib_mask   *mask_buffer;

/* The last few C;S stores kept in memory: a graphics door stores a frame and draws it straight back */
static struct {
	char     path[APC_PATH_MAX];
	uint8_t *data;
	size_t   len;
} store_memo[STORE_MEMO_COUNT];
static int store_memo_next;

/* ----- small helpers ----- */

void
apc_send(const char *buf, size_t len)
{
	if (buf != NULL && len > 0)
		(void)conn_send(buf, len, 1000);
}

static void
forward_slashes(char *s)
{
	for (; *s; s++) {
		if (*s == '\\')
			*s = '/';
	}
}

static char *
apc_strndup(const char *s, size_t n)
{
	char *ret = malloc(n + 1);

	if (ret != NULL) {
		memcpy(ret, s, n);
		ret[n] = '\0';
	}
	return ret;
}

static void *
b64_decode_alloc(const char *src, size_t srclen, size_t *outlen)
{
	char   *ret;
	ssize_t ol;
	size_t  sz = (srclen + 3) / 4 * 3 + 1;

	ret = malloc(sz);
	if (ret == NULL)
		return NULL;
	ol = b64_decode(ret, sz, src, srclen);
	if (ol == -1) {
		free(ret);
		return NULL;
	}
	if (outlen != NULL)
		*outlen = (size_t)ol;
	return ret;
}

bool
apc_cache_path(const char *rel, char *out, size_t outsz)
{
	size_t      rootlen = strlen(g_cache_root);
	const char *c;

	if (rootlen == 0 || rel == NULL || *rel == '\0')
		return false;
	if (rel[0] == '/' || rel[0] == '\\' || strchr(rel, ':') != NULL)
		return false;
	for (c = rel; *c; c++) {
		if (c[0] == '.' && c[1] == '.' && (c == rel || c[-1] == '/' || c[-1] == '\\')
		    && (c[2] == '\0' || c[2] == '/' || c[2] == '\\'))
			return false;
	}
	if (rootlen + strlen(rel) + 1 > outsz)
		return false;
	memcpy(out, g_cache_root, rootlen);
	strcpy(out + rootlen, rel);
	/* Backslashes separate too (as on Windows); both kinds were checked for ".." above */
	forward_slashes(out + rootlen);
	return true;
}

/* Creates every directory on the way to `path` (not the last component unless `include_last`). */
static void
make_dirs(const char *path, bool include_last)
{
	char  tmp[APC_PATH_MAX];
	char *p;

	if (strlen(path) >= sizeof(tmp))
		return;
	strcpy(tmp, path);
	for (p = tmp; *p; p++) {
		if (*p != '/' || p == tmp)
			continue;
		*p = '\0';
		(void)mkdir(tmp, 0755);
		*p = '/';
	}
	if (include_last)
		(void)mkdir(tmp, 0755);
}

static void
memo_clear(void)
{
	int i;

	for (i = 0; i < STORE_MEMO_COUNT; i++) {
		free(store_memo[i].data);
		store_memo[i].data    = NULL;
		store_memo[i].len     = 0;
		store_memo[i].path[0] = '\0';
	}
}

/* Takes ownership of `data`. Case-insensitive, like the default APFS volume (and NTFS on Windows). */
static void
memo_put(const char *path, uint8_t *data, size_t len)
{
	int i;

	for (i = 0; i < STORE_MEMO_COUNT; i++) {
		if (store_memo[i].data != NULL && strcasecmp(store_memo[i].path, path) == 0)
			break;
	}
	if (i == STORE_MEMO_COUNT) {
		i = store_memo_next;
		store_memo_next = (store_memo_next + 1) % STORE_MEMO_COUNT;
	}
	free(store_memo[i].data);
	strcpy(store_memo[i].path, path);
	store_memo[i].data = data;
	store_memo[i].len  = len;
}

/* A malloc()d copy of a cache file: from the store memo when it was just stored, else from disk. */
static uint8_t *
read_cache_file(const char *path, size_t *len)
{
	FILE    *f;
	uint8_t *buf;
	off_t    size;
	int      i;

	for (i = 0; i < STORE_MEMO_COUNT; i++) {
		if (store_memo[i].data != NULL && strcasecmp(store_memo[i].path, path) == 0) {
			buf = malloc(store_memo[i].len ? store_memo[i].len : 1);
			if (buf == NULL)
				return NULL;
			memcpy(buf, store_memo[i].data, store_memo[i].len);
			*len = store_memo[i].len;
			return buf;
		}
	}

	if ((f = fopen(path, "rb")) == NULL)
		return NULL;
	if (fseeko(f, 0, SEEK_END) != 0 || (size = ftello(f)) < 0 || size > (off_t)1 << 31
	    || fseeko(f, 0, SEEK_SET) != 0) {
		fclose(f);
		return NULL;
	}
	buf = malloc(size ? (size_t)size : 1);
	if (buf != NULL && size > 0 && fread(buf, 1, (size_t)size, f) != (size_t)size) {
		free(buf);
		buf = NULL;
	}
	fclose(f);
	if (buf != NULL)
		*len = (size_t)size;
	return buf;
}

/* ----- cache store / list ----- */

static void
cache_store(char *strbuf, size_t slen)
{
	char     path[APC_PATH_MAX];
	char    *p;
	uint8_t *buf;
	size_t   len;
	bool     ok;
	FILE    *f;

	/* SyncTERM:C;S;<name>;<base64> */
	p = strchr(strbuf + 13, ';');
	if (p == NULL)
		return;
	*p = '\0';
	ok = apc_cache_path(strbuf + 13, path, sizeof(path));
	*p = ';';
	if (!ok)
		return;
	p++;
	buf = b64_decode_alloc(p, slen - (size_t)(p - strbuf), &len);
	if (buf == NULL)
		return;
	make_dirs(path, false);
	if ((f = fopen(path, "wb")) != NULL) {
		fwrite(buf, 1, len, f);
		fclose(f);
		memo_put(path, buf, len);
		return;
	}
	free(buf);
}

/* The cache root with glob()'s metacharacters escaped, then the board's pattern as is: the board picks the
 * wildcards, but the directory's own name (a board called "[BBS]") must match literally. */
static bool
glob_pattern(const char *full, size_t rootlen, char *out, size_t outsz)
{
	size_t n = 0;
	size_t i;

	for (i = 0; i < rootlen; i++) {
		if (strchr("*?[\\", full[i]) != NULL) {
			if (n + 1 >= outsz)
				return false;
			out[n++] = '\\';
		}
		if (n + 1 >= outsz)
			return false;
		out[n++] = full[i];
	}
	if (n + strlen(full + rootlen) + 1 > outsz)
		return false;
	strcpy(out + n, full + rootlen);
	return true;
}

#define MAX_NAME_LINE (PATH_MAX + 128)

static FILE *
md5_fopen(const char *path, const char *mode)
{
	return fopen(path, mode);
}

static bool
md5_exists(const char *path)
{
	struct stat st;

	return stat(path, &st) == 0;
}

static bool
md5_replace(const char *from, const char *to)
{
	return rename(from, to) == 0;
}

/* ----- C;L's MD5s, remembered -----
 * C;L answers with every cached file's MD5. Reading a board's whole cache for every listing (Dead Modem Society:
 * 319 files, 31 MB) sometimes took longer than Rainwire's 3 s wait for the answer on Windows, so The Wall showed
 * 3 s late and the board, taking the cache for empty, sent every picture again (2026-11-09). Each file's MD5 is now
 * kept with its size and modified time, in memory and in "<board folder>.md5" beside the board's folder, and only a
 * new or changed file is read. The answer is built whole and sent in 4 KB pieces instead of ~4 writes per file. */

typedef struct {
	char    *name;
	uint64_t size;
	int64_t  mtime;
	char     hex[MD5_DIGEST_SIZE * 2 + 1];
	bool     seen;   /* listed this time, or its file still exists (kept when saved) */
} md5_ent;

static md5_ent *g_md5;
static size_t   g_md5_n, g_md5_cap;
static char     g_md5_dir[APC_PATH_MAX];   /* the folder the entries are for, with its trailing '/' */
static bool     g_md5_dirty;

typedef struct {
	char  *p;
	size_t n, cap;
} sbuf;

static void
sb_add(sbuf *b, const char *s, size_t len)
{
	if (b->p == NULL && b->cap == (size_t)-1)
		return;   /* out of memory earlier */
	if (b->n + len + 1 > b->cap) {
		size_t cap = b->cap ? b->cap : 16384;
		char  *p;

		while (b->n + len + 1 > cap)
			cap *= 2;
		if ((p = realloc(b->p, cap)) == NULL) {
			free(b->p);
			b->p = NULL;
			b->n = 0;
			b->cap = (size_t)-1;
			return;
		}
		b->p = p;
		b->cap = cap;
	}
	memcpy(b->p + b->n, s, len);
	b->n += len;
	b->p[b->n] = '\0';
}

/* "<root>/<board>/" -> "<root>/<board>.md5" */
static bool
md5_index_path(const char *dir, char *out, size_t cap)
{
	size_t n = strlen(dir);

	if (n < 2 || dir[n - 1] != '/' || n - 1 + 5 > cap)
		return false;
	memcpy(out, dir, n - 1);
	strcpy(out + n - 1, ".md5");
	return true;
}

static void
md5_forget(void)
{
	size_t i;

	for (i = 0; i < g_md5_n; i++)
		free(g_md5[i].name);
	g_md5_n = 0;
	g_md5_dir[0] = '\0';
	g_md5_dirty = false;
}

static md5_ent *
md5_find(const char *name)
{
	size_t i;

	for (i = 0; i < g_md5_n; i++)
		if (strcmp(g_md5[i].name, name) == 0)
			return &g_md5[i];
	return NULL;
}

static md5_ent *
md5_add(const char *name)
{
	md5_ent *e;

	if (g_md5_n == g_md5_cap) {
		size_t   cap = g_md5_cap ? g_md5_cap * 2 : 256;
		md5_ent *p = realloc(g_md5, cap * sizeof(*p));

		if (p == NULL)
			return NULL;
		g_md5 = p;
		g_md5_cap = cap;
	}
	e = &g_md5[g_md5_n];
	memset(e, 0, sizeof(*e));
	if ((e->name = strdup(name)) == NULL)
		return NULL;
	g_md5_n++;
	return e;
}

/* The entries for folder dir: loaded from its index the first time (or when another board's folder is listed). */
static void
md5_use_dir(const char *dir)
{
	char  path[APC_PATH_MAX];
	char  line[MAX_NAME_LINE];
	FILE *f;

	if (strcmp(dir, g_md5_dir) == 0)
		return;
	md5_forget();
	if (strlen(dir) >= sizeof(g_md5_dir))
		return;
	strcpy(g_md5_dir, dir);
	if (!md5_index_path(dir, path, sizeof(path)) || (f = md5_fopen(path, "rb")) == NULL)
		return;
	/* size TAB mtime TAB md5 TAB name */
	while (fgets(line, sizeof(line), f) != NULL) {
		char              *t1, *t2, *t3, *nl;
		unsigned long long size;
		long long          mtime;
		md5_ent           *e;

		if ((nl = strchr(line, '\n')) != NULL)
			*nl = '\0';
		if ((t1 = strchr(line, '\t')) == NULL || (t2 = strchr(t1 + 1, '\t')) == NULL
		    || (t3 = strchr(t2 + 1, '\t')) == NULL || t3 - (t2 + 1) != MD5_DIGEST_SIZE * 2 || t3[1] == '\0')
			continue;
		size = strtoull(line, NULL, 10);
		mtime = strtoll(t1 + 1, NULL, 10);
		if (md5_find(t3 + 1) != NULL || (e = md5_add(t3 + 1)) == NULL)
			continue;
		e->size = size;
		e->mtime = mtime;
		memcpy(e->hex, t2 + 1, MD5_DIGEST_SIZE * 2);
		e->hex[MD5_DIGEST_SIZE * 2] = '\0';
	}
	fclose(f);
}

/* full's MD5 into hex: remembered when its size and modified time haven't changed, read otherwise. */
static bool
md5_of(const char *full, const char *name, uint64_t size, int64_t mtime, char *hex, uint8_t *chunk)
{
	md5_ent *e = name != NULL ? md5_find(name) : NULL;   /* name NULL: not in the folder the entries are for */
	FILE    *f;
	MD5      ctx;
	BYTE     digest[MD5_DIGEST_SIZE];
	size_t   rc;

	if (e != NULL && e->size == size && e->mtime == mtime) {
		e->seen = true;
		strcpy(hex, e->hex);
		return true;
	}
	if ((f = md5_fopen(full, "rb")) == NULL)
		return false;
	MD5_open(&ctx);
	while ((rc = fread(chunk, 1, 1024 * 32, f)) > 0)
		MD5_digest(&ctx, chunk, rc);
	MD5_close(&ctx, digest);
	fclose(f);
	MD5_hex(hex, digest);
	if (e == NULL && name != NULL)
		e = md5_add(name);
	if (e != NULL) {
		e->size = size;
		e->mtime = mtime;
		strcpy(e->hex, hex);
		e->seen = true;
		g_md5_dirty = true;
	}
	return true;
}

/* Writes the index when something was read. Entries not listed this time are kept while their file exists (a
 * listing may have been of a pattern), dropped when it's gone. */
static void
md5_save(void)
{
	char   path[APC_PATH_MAX];
	char   tmp[APC_PATH_MAX + 8];
	char   full[APC_PATH_MAX];
	FILE  *f;
	size_t i, keep = 0;

	if (!g_md5_dirty || !md5_index_path(g_md5_dir, path, sizeof(path)))
		return;
	for (i = 0; i < g_md5_n; i++) {
		if (!g_md5[i].seen) {
			if (strlen(g_md5_dir) + strlen(g_md5[i].name) + 1 > sizeof(full))
				continue;
			strcpy(full, g_md5_dir);
			strcat(full, g_md5[i].name);
			if (!md5_exists(full)) {
				free(g_md5[i].name);
				continue;
			}
		}
		g_md5[keep++] = g_md5[i];
	}
	g_md5_n = keep;
	snprintf(tmp, sizeof(tmp), "%s.tmp", path);
	if ((f = md5_fopen(tmp, "wb")) == NULL)
		return;
	for (i = 0; i < g_md5_n; i++)
		fprintf(f, "%llu\t%lld\t%s\t%s\n", (unsigned long long)g_md5[i].size, (long long)g_md5[i].mtime,
		        g_md5[i].hex, g_md5[i].name);
	if (fclose(f) == 0 && md5_replace(tmp, path))
		g_md5_dirty = false;
}

/* Sends all of buf in pieces: conn_send() puts at most what its 16 KB output buffer has free (BUFFER_SIZE) and
 * drops the rest of a bigger write, so one 26 KB listing went out cut off with no ST (2026-11-09). */
static void
apc_send_all(const char *buf, size_t len)
{
	while (len > 0) {
		size_t piece = len < 4096 ? len : 4096;
		int    sent = conn_send(buf, piece, 1000);

		if (sent <= 0)
			return;   /* the connection is gone or stuck */
		if ((size_t)sent > piece)
			sent = (int)piece;   /* telnet counts its escaped bytes (a listing has no 0xFF to double) */
		buf += sent;
		len -= (size_t)sent;
	}
}

/* Starts a listing of folder dir: every entry unseen until listed. */
static void
md5_begin(const char *dir)
{
	size_t i;

	md5_use_dir(dir);
	for (i = 0; i < g_md5_n; i++)
		g_md5[i].seen = false;
}

static void
cache_list(char *strbuf, size_t slen)
{
	static const char head[] = "\x1b_SyncTERM:C;L\n";
	const char       *pattern = "*";
	char              path[APC_PATH_MAX];
	char              dir[APC_PATH_MAX];
	char              globpat[APC_PATH_MAX * 2];
	char              hex[MD5_DIGEST_SIZE * 2 + 1];
	char             *slash;
	glob_t            g;
	size_t            i, dirlen;
	sbuf              out = {0};
	bool              memo;

	if (strbuf[12] != '\0' && strbuf[12] != ';')
		return;
	if (strbuf[12] == ';' && slen > 13)
		pattern = strbuf + 13;
	if (!apc_cache_path(pattern, path, sizeof(path))
	    || !glob_pattern(path, strlen(g_cache_root), globpat, sizeof(globpat))) {
		apc_send("\x1b_SyncTERM:C;L\n\x1b\\", 17);
		return;
	}
	strcpy(dir, path);
	slash = strrchr(dir, '/');
	if (slash != NULL)
		slash[1] = '\0';
	dirlen = strlen(dir);

	memo = strcmp(dir, g_cache_root) == 0;   /* remembered for the board's own folder (its index sits beside it) */
	sb_add(&out, head, sizeof(head) - 1);
	if (memo)
		md5_begin(dir);
	memset(&g, 0, sizeof(g));
	if (glob(globpat, GLOB_MARK, NULL, &g) == 0) {
		uint8_t *chunk = malloc(1024 * 32);

		for (i = 0; chunk != NULL && i < (size_t)g.gl_pathc; i++) {
			const char *full = g.gl_pathv[i];
			const char *name;
			size_t      flen = strlen(full);
			char        resolved[PATH_MAX];
			struct stat st;
			int64_t     mtime;
			bool        here;

			if (flen == 0 || full[flen - 1] == '/')   /* GLOB_MARK marks directories */
				continue;
			/* glob() expands wildcards in every segment, and a segment starting with '.' may match ".."
			 * (".*" / ".?" / ".[.]"), so a pattern could climb out of the cache. Windows only allows wildcards
			 * in the last component and checks the resolved path: check the resolved path here too. */
			if (realpath(full, resolved) == NULL || strncmp(resolved, g_cache_root, strlen(g_cache_root)) != 0)
				continue;
			if (stat(full, &st) != 0)
				continue;
#ifdef __APPLE__
			mtime = (int64_t)st.st_mtimespec.tv_sec * 1000000000 + st.st_mtimespec.tv_nsec;
#else
			mtime = (int64_t)st.st_mtim.tv_sec * 1000000000 + st.st_mtim.tv_nsec;
#endif
			name = strrchr(full, '/');
			name = name != NULL ? name + 1 : full;
			/* remembered only for files straight in dir (a wildcard in a folder's name lists other folders too) */
			here = memo && strncmp(full, dir, dirlen) == 0 && strchr(full + dirlen, '/') == NULL;
			sb_add(&out, name, strlen(name));
			sb_add(&out, "\t", 1);
			if (md5_of(full, here ? name : NULL, (uint64_t)st.st_size, mtime, hex, chunk))
				sb_add(&out, hex, strlen(hex));
			sb_add(&out, "\n", 1);
		}
		free(chunk);
	}
	globfree(&g);
	if (memo)
		md5_save();
	sb_add(&out, "\x1b\\", 2);
	if (out.p != NULL)
		apc_send_all(out.p, out.n);
	else
		apc_send("\x1b_SyncTERM:C;L\n\x1b\\", 17);   /* out of memory: an empty list */
	free(out.p);
}

/* ----- images ----- */

static struct ciolib_pixels *
read_image_source(enum image_type type, const char *src, size_t srclen, bool blob)
{
	char                  path[APC_PATH_MAX];
	uint8_t              *buf;
	size_t                len = 0;
	struct ciolib_pixels *ret;

	if (blob)
		buf = b64_decode_alloc(src, srclen, &len);
	else
		buf = apc_cache_path(src, path, sizeof(path)) ? read_cache_file(path, &len) : NULL;
	if (buf == NULL)
		return NULL;
	ret = (type == IMAGE_JXL) ? apc_image_decode_jxl(buf, len) : apc_image_decode_ppm(buf, len);
	free(buf);
	return ret;
}

static struct ciolib_mask *
read_mask_file(const char *name)
{
	char                path[APC_PATH_MAX];
	uint8_t            *buf;
	size_t              len = 0;
	struct ciolib_mask *ret;

	if (!apc_cache_path(name, path, sizeof(path)) || (buf = read_cache_file(path, &len)) == NULL)
		return NULL;
	ret = apc_image_decode_pbm(buf, len);
	free(buf);
	return ret;
}

/* Upstream's blitpixels: source rectangle, integer zoom and flips, drawn at (dx, dy), clipped at the
 * top/left edge, through macos_ciolib_setpixels (which clips right/bottom and applies the mask). */
static void
draw_pixels(struct ciolib_pixels *px, struct ciolib_mask *mask, unsigned long sx, unsigned long sy,
            unsigned long sw, unsigned long sh, long dx, long dy, unsigned long mx, unsigned long my,
            unsigned long zx, unsigned long zy, uint32_t flags)
{
	struct ciolib_pixels *src    = px;
	struct ciolib_pixels *scaled = NULL;
	unsigned long         w;
	unsigned long         h;
	unsigned long         srcx0  = sx;
	unsigned long         srcy0  = sy;
	unsigned long         xoff   = 0;
	unsigned long         yoff   = 0;
	long                  x0     = dx;
	long                  y0     = dy;

	if (px == NULL || px->pixels == NULL || zx == 0 || zy == 0 || zx > 64 || zy > 64)
		return;
	if (sx >= px->width || sy >= px->height)
		return;
	if (sw > px->width - sx)
		sw = px->width - sx;
	if (sh > px->height - sy)
		sh = px->height - sy;
	if (sw == 0 || sh == 0)
		return;
	w = sw * zx;
	h = sh * zy;
	if (w > APC_MAX_DIM || h > APC_MAX_DIM)
		return;

	if (zx != 1 || zy != 1 || flags != 0) {
		unsigned long x;
		unsigned long y;

		scaled = apc_image_alloc_pixels((uint32_t)w, (uint32_t)h);
		if (scaled == NULL)
			return;
		for (y = 0; y < h; y++) {
			unsigned long   iy  = y / zy;
			const uint32_t *row;

			if (flags & APC_BLIT_FLIP_Y)
				iy = sh - 1 - iy;
			row = px->pixels + (sy + iy) * px->width + sx;
			for (x = 0; x < w; x++) {
				unsigned long ix = x / zx;

				if (flags & APC_BLIT_FLIP_X)
					ix = sw - 1 - ix;
				scaled->pixels[y * w + x] = row[ix];
			}
		}
		src   = scaled;
		srcx0 = 0;
		srcy0 = 0;
	}

	if (x0 < 0) {
		xoff = (unsigned long)(-x0);
		x0   = 0;
	}
	if (y0 < 0) {
		yoff = (unsigned long)(-y0);
		y0   = 0;
	}
	if (xoff < w && yoff < h && x0 < APC_MAX_DIM && y0 < APC_MAX_DIM)
		macos_ciolib_setpixels((uint32_t)x0, (uint32_t)y0,
		                       (uint32_t)(x0 + (long)(w - xoff) - 1), (uint32_t)(y0 + (long)(h - yoff) - 1),
		                       (uint32_t)(srcx0 + xoff), (uint32_t)(srcy0 + yoff),
		                       (uint32_t)(mx + xoff), (uint32_t)(my + yoff), src, mask);
	apc_image_free_pixels(scaled);
}

/* Shared option parser for C;Draw* and P;Paste. Returns false on a malformed option. `p` is left on the
 * first non-option token (the payload, for Draw). */
struct draw_opts {
	unsigned long       sx, sy, sw, sh, mx, my, mw, mh, zx, zy, bufnum;
	long                dx, dy;
	uint32_t            flags;
	char               *maskname;
	struct ciolib_mask *ctmask;
	size_t              mlen;
	bool                mbuf;
};

static void
draw_opts_free(struct draw_opts *o)
{
	free(o->maskname);
	if (!o->mbuf)
		apc_image_free_mask(o->ctmask);
}

static bool
parse_draw_opts(char **pp, struct draw_opts *o, bool paste)
{
	char           *p;
	char           *p2;
	unsigned long  *val;
	long           *sval;
	size_t          poff;

	for (p = *pp; p && *p == ';'; p = strchr(p + 1, ';')) {
		val  = NULL;
		sval = NULL;
		poff = 3;
		switch (p[1]) {
			case 'B':
				if (paste) {
					val  = &o->bufnum;
					poff = 2;
				}
				break;
			case 'S':
				switch (p[2]) {
					case 'X': val = &o->sx; break;
					case 'Y': val = &o->sy; break;
					case 'W': val = &o->sw; break;
					case 'H': val = &o->sh; break;
				}
				break;
			case 'D':
				switch (p[2]) {
					case 'X': sval = &o->dx; break;
					case 'Y': sval = &o->dy; break;
				}
				break;
			case 'F':
				switch (p[2]) {
					case 'X':
						o->flags |= APC_BLIT_FLIP_X;
						continue;
					case 'Y':
						o->flags |= APC_BLIT_FLIP_Y;
						continue;
				}
				break;
			case 'M':
				if (p[2] == 'X') { val = &o->mx; break; }
				if (p[2] == 'Y') { val = &o->my; break; }
				if (p[2] == 'W') { val = &o->mw; break; }
				if (p[2] == 'H') { val = &o->mh; break; }
				if (strncmp(p + 2, "FILE=", 5) == 0) {
					p2 = strchr(p + 7, ';');
					if (p2 == NULL) {
						if (!paste)
							return false;
						p2 = p + 7 + strlen(p + 7);
					}
					if (!o->mbuf)
						apc_image_free_mask(o->ctmask);
					o->mbuf   = false;
					o->ctmask = NULL;
					free(o->maskname);
					o->maskname = apc_strndup(p + 7, (size_t)(p2 - (p + 7)));
					continue;
				}
				if (strncmp(p + 2, "ASK=", 4) == 0) {
					p2 = strchr(p + 6, ';');
					if (p2 == NULL) {
						if (!paste)
							return false;
						p2 = p + 6 + strlen(p + 6);
					}
					free(o->maskname);
					o->maskname = NULL;
					if (!o->mbuf)
						apc_image_free_mask(o->ctmask);
					o->mbuf   = false;
					o->ctmask = apc_image_alloc_mask(0, 0);
					if (o->ctmask == NULL)
						return false;
					o->ctmask->bits = b64_decode_alloc(p + 6, (size_t)(p2 - (p + 6)), &o->mlen);
					if (o->ctmask->bits == NULL)
						return false;
					continue;
				}
				if (strncmp(p + 2, "BUF", 3) == 0) {
					if (!o->mbuf)
						apc_image_free_mask(o->ctmask);
					o->ctmask = NULL;
					o->mbuf   = true;
					continue;
				}
				break;
			case 'Z':
				switch (p[2]) {
					case 'X': val = &o->zx; break;
					case 'Y': val = &o->zy; break;
				}
				break;
		}
		if (val == NULL && sval == NULL)
			break;            /* the payload (Draw) or a bad key (Paste, checked by the caller) */
		if (p[poff] != '=')
			return false;
		if (val != NULL)
			*val = strtoul(p + poff + 1, NULL, 10);
		else
			*sval = strtol(p + poff + 1, NULL, 10);
	}
	*pp = p;
	return true;
}

/* Resolves the mask for a blit of sw x sh; false when the mask can't cover it. */
static bool
resolve_mask(struct draw_opts *o)
{
	if (o->ctmask != NULL) {
		if (o->mlen < (o->sw * o->sh + 7) / 8)
			return false;
		if (o->mw == 0)
			o->mw = o->sw;
		if (o->mh == 0)
			o->mh = o->sh;
		if (o->mlen < (o->mw * o->mh + 7) / 8)
			return false;
		o->ctmask->width  = (uint32_t)o->mw;
		o->ctmask->height = (uint32_t)o->mh;
	}
	if (o->maskname != NULL) {
		apc_image_free_mask(o->ctmask);
		o->ctmask = read_mask_file(o->maskname);
		if (o->ctmask == NULL || o->ctmask->width < o->sw || o->ctmask->height < o->sh)
			return false;
	}
	if (o->mbuf)
		o->ctmask = mask_buffer;
	return true;
}

static void
draw_image_str_handler(char *str, size_t slen, size_t optoff, enum image_type type, bool blob)
{
	struct draw_opts      o    = {0};
	struct ciolib_pixels *imgp = NULL;
	char                 *p    = str + optoff;

	o.zx = 1;
	o.zy = 1;
	if (!parse_draw_opts(&p, &o, false) || p == NULL || *p != ';' || slen <= (size_t)(p + 1 - str))
		goto done;
	imgp = read_image_source(type, p + 1, slen - (size_t)(p + 1 - str), blob);
	if (imgp == NULL)
		goto done;
	if (o.sw == 0)
		o.sw = imgp->width > o.sx ? imgp->width - o.sx : 0;
	if (o.sh == 0)
		o.sh = imgp->height > o.sy ? imgp->height - o.sy : 0;
	if (!resolve_mask(&o))
		goto done;
	draw_pixels(imgp, o.ctmask, o.sx, o.sy, o.sw, o.sh, o.dx, o.dy, o.mx, o.my, o.zx, o.zy, o.flags);
done:
	draw_opts_free(&o);
	apc_image_free_pixels(imgp);
}

static void
load_image_str_handler(char *str, size_t slen, size_t optoff, enum image_type type, bool blob)
{
	char                 *p;
	struct ciolib_pixels *imgp   = NULL;
	unsigned long         bufnum = 0;

	for (p = str + optoff; p && *p == ';'; p = strchr(p + 1, ';')) {
		if (p[1] != 'B' || p[2] != '=')
			break;
		bufnum = strtoul(p + 3, NULL, 10);
	}
	if (bufnum >= sizeof(pixmap_buffer) / sizeof(pixmap_buffer[0]))
		return;
	apc_image_free_pixels(pixmap_buffer[bufnum]);
	pixmap_buffer[bufnum] = NULL;
	if (p == NULL || *p != ';' || slen <= (size_t)(p + 1 - str))
		return;
	imgp = read_image_source(type, p + 1, slen - (size_t)(p + 1 - str), blob);
	pixmap_buffer[bufnum] = imgp;
}

static void
load_pbm_str_handler(char *str, size_t slen, size_t optoff, bool blob)
{
	char    *p = str + optoff;
	uint8_t *buf;
	size_t   buflen = 0;

	if (*p != ';' || slen <= (size_t)(p + 1 - str))
		return;
	apc_image_free_mask(mask_buffer);
	mask_buffer = NULL;
	if (blob) {
		buf = b64_decode_alloc(p + 1, slen - (size_t)(p + 1 - str), &buflen);
		if (buf == NULL)
			return;
		mask_buffer = apc_image_decode_pbm(buf, buflen);
		free(buf);
		return;
	}
	mask_buffer = read_mask_file(p + 1);
}

static void
copy_pixmap(char *str)
{
	unsigned long   x      = 0;
	unsigned long   y      = 0;
	unsigned long   w      = 0;
	unsigned long   h      = 0;
	unsigned long   bufnum = 0;
	unsigned long  *val;
	char           *p;
	uint32_t       *buf;
	unsigned long   bw;
	unsigned long   bh;
	struct ciolib_pixels *out;

	for (p = str + 15; p && *p == ';'; p = strchr(p + 1, ';')) {
		val = NULL;
		switch (p[1]) {
			case 'X': val = &x; break;
			case 'Y': val = &y; break;
			case 'W': val = &w; break;
			case 'H': val = &h; break;
			case 'B': val = &bufnum; break;
		}
		if (val == NULL || p[2] != '=')
			return;
		*val = strtoul(p + 3, NULL, 10);
	}
	if (bufnum >= sizeof(pixmap_buffer) / sizeof(pixmap_buffer[0]))
		return;
	apc_image_free_pixels(pixmap_buffer[bufnum]);
	pixmap_buffer[bufnum] = NULL;

	macos_ciolib_lock();
	buf = macos_ciolib_get_pixel_buffer();
	bw  = (unsigned long)macos_ciolib_get_pixel_width();
	bh  = (unsigned long)macos_ciolib_get_pixel_height();
	if (buf != NULL && x < bw && y < bh) {
		if (w == 0 || w > bw - x)
			w = bw - x;
		if (h == 0 || h > bh - y)
			h = bh - y;
		out = apc_image_alloc_pixels((uint32_t)w, (uint32_t)h);
		if (out != NULL) {
			unsigned long row;
			unsigned long col;

			for (row = 0; row < h; row++) {
				for (col = 0; col < w; col++)
					out->pixels[row * w + col] = CIOLIB_COLOR_RGB | (buf[(y + row) * bw + x + col] & 0x00FFFFFF);
			}
			pixmap_buffer[bufnum] = out;
		}
	}
	macos_ciolib_unlock();
}

static void
paste_pixmap(char *str, size_t slen)
{
	struct draw_opts o = {0};
	char            *p = str + 16;

	(void)slen;
	o.zx = 1;
	o.zy = 1;
	if (!parse_draw_opts(&p, &o, true) || (p != NULL && *p == ';'))   /* Paste has no payload: leftovers are bad keys */
		goto done;
	if (o.bufnum >= sizeof(pixmap_buffer) / sizeof(pixmap_buffer[0]) || pixmap_buffer[o.bufnum] == NULL)
		goto done;
	if (o.sw == 0)
		o.sw = pixmap_buffer[o.bufnum]->width > o.sx ? pixmap_buffer[o.bufnum]->width - o.sx : 0;
	if (o.sh == 0)
		o.sh = pixmap_buffer[o.bufnum]->height > o.sy ? pixmap_buffer[o.bufnum]->height - o.sy : 0;
	if (!resolve_mask(&o))
		goto done;
	draw_pixels(pixmap_buffer[o.bufnum], o.ctmask, o.sx, o.sy, o.sw, o.sh, o.dx, o.dy, o.mx, o.my, o.zx, o.zy,
	            o.flags);
done:
	draw_opts_free(&o);
}

/* ----- dispatcher ----- */

static void
macos_apc_handler(char *strbuf, size_t slen, char *retbuf, size_t retsize, void *cbdata)
{
	(void)retbuf;
	(void)retsize;
	(void)cbdata;

	/* Rainwire:Caps;Query, the client capability query (osc_ext.c, 12.62) */
	if (osc_ext_apc_handler(strbuf, slen))
		return;

	/* TRACE has its own namespace and handler (trace_bridge.c); nothing below sees its commands */
	if (trace_apc_handler(strbuf, slen))
		return;
	/* So does Rainwire's window protocol (wm_bridge.c) */
	if (wm_apc_handler(strbuf, slen))
		return;
	/* And Rainwire's pictures, TERMinator:Pic (pic_bridge.c) */
	if (pic_apc_handler(strbuf, slen))
		return;
	/* And Rainwire's menus drawn by the app, Rainwire:UI (ui_bridge.c, 1.1.6) */
	if (ui_apc_handler(strbuf, slen))
		return;

	if (strbuf == NULL || strncmp(strbuf, "SyncTERM:", 9) != 0)
		return;

	if (strncmp(strbuf, "SyncTERM:C;S;", 13) == 0)
		cache_store(strbuf, slen);
	else if (strncmp(strbuf, "SyncTERM:C;LoadPPMBlob", 22) == 0)
		load_image_str_handler(strbuf, slen, 22, IMAGE_PPM, true);
	else if (strncmp(strbuf, "SyncTERM:C;LoadPPM", 18) == 0)
		load_image_str_handler(strbuf, slen, 18, IMAGE_PPM, false);
	else if (strncmp(strbuf, "SyncTERM:C;LoadPBMBlob", 22) == 0)
		load_pbm_str_handler(strbuf, slen, 22, true);
	else if (strncmp(strbuf, "SyncTERM:C;LoadPBM", 18) == 0)
		load_pbm_str_handler(strbuf, slen, 18, false);
	else if (strncmp(strbuf, "SyncTERM:C;LoadJXLBlob", 22) == 0)
		load_image_str_handler(strbuf, slen, 22, IMAGE_JXL, true);
	else if (strncmp(strbuf, "SyncTERM:C;LoadJXL", 18) == 0)
		load_image_str_handler(strbuf, slen, 18, IMAGE_JXL, false);
	else if (strncmp(strbuf, "SyncTERM:C;L", 12) == 0)
		cache_list(strbuf, slen);
	else if (strncmp(strbuf, "SyncTERM:C;DrawPPMBlob", 22) == 0)
		draw_image_str_handler(strbuf, slen, 22, IMAGE_PPM, true);
	else if (strncmp(strbuf, "SyncTERM:C;DrawPPM", 18) == 0)
		draw_image_str_handler(strbuf, slen, 18, IMAGE_PPM, false);
	else if (strncmp(strbuf, "SyncTERM:C;DrawJXLBlob", 22) == 0)
		draw_image_str_handler(strbuf, slen, 22, IMAGE_JXL, true);
	else if (strncmp(strbuf, "SyncTERM:C;DrawJXL", 18) == 0)
		draw_image_str_handler(strbuf, slen, 18, IMAGE_JXL, false);
	else if (strncmp(strbuf, "SyncTERM:P;Copy", 15) == 0)
		copy_pixmap(strbuf);
	else if (strncmp(strbuf, "SyncTERM:P;Paste", 16) == 0)
		paste_pixmap(strbuf, slen);
	else if (strncmp(strbuf, "SyncTERM:Q;JXL", 14) == 0) {
		if (apc_image_jxl_supported())
			apc_send("\x1b[=1;1-n", 8);
	}
	else if (strncmp(strbuf, "SyncTERM:A;", 11) == 0)
		audio_apc_handler(strbuf + 11, slen - 11);
	else if (strncmp(strbuf, "SyncTERM:Q;", 11) == 0)
		feature_query_handler(strbuf + 11, slen - 11);
}

/* DA reply: CTerm 1.332 (this cterm is 1.324). Doors gate on the version for what this bridge implements --
 * APC blob verbs (1.329), Q;libsndfileFormat (1.331), graphics ZX/ZY/FX/FY and negative DX/DY (1.332, which
 * lets SyncDoom send native 320x200 frames instead of 640x400) -- and the macOS cterm.c fork takes the 1.328
 * DECSDM sense under __APPLE__. SGR pixel mouse (1.330) is probed with DECRQM, not by version. */
#define MACOS_CTERM_DA "\x1b[=67;84;101;114;109;1;332c"

void
macos_apc_attach(struct cterminal *cterm)
{
	if (cterm == NULL)
		return;
	osc_ext_attach(cterm);   /* OSC 0/2 title, 8 hyperlinks, 52 clipboard (osc_ext.c, 12.62) */
	if (cterm->apc_handler != macos_apc_handler) {
		cterm->apc_handler      = macos_apc_handler;
		cterm->apc_handler_data = NULL;
	}
	if (strcmp(cterm->DA, MACOS_CTERM_DA) != 0)
		strcpy(cterm->DA, MACOS_CTERM_DA);
}

void
macos_apc_poll(void)
{
	audio_apc_poll();
}

void
macos_apc_session_reset(void)
{
	size_t i;

	osc_ext_session_reset();
	pic_session_reset();     /* queued TERMinator:Pic commands belong to the call that ended */
	ui_session_reset();      /* and queued Rainwire:UI messages */
	audio_apc_cleanup();
	trace_session_reset();   /* queued TRACE commands belong to the call that ended */
	for (i = 0; i < sizeof(pixmap_buffer) / sizeof(pixmap_buffer[0]); i++) {
		apc_image_free_pixels(pixmap_buffer[i]);
		pixmap_buffer[i] = NULL;
	}
	apc_image_free_mask(mask_buffer);
	mask_buffer = NULL;
	memo_clear();
}

/* ----- exports (native_bridge.h) ----- */

/* The board's cache directory (UTF-8, absolute). Created if missing; NULL or "" turns caching off. */
void
native_set_apc_cache_dir(const char *utf8dir)
{
	char   resolved[PATH_MAX];
	size_t len;

	g_cache_root[0] = '\0';
	if (utf8dir == NULL || *utf8dir != '/')
		return;
	make_dirs(utf8dir, true);
	/* Canonical, so paths built on it can be globbed and compared as they are */
	if (realpath(utf8dir, resolved) == NULL)
		return;
	len = strlen(resolved);
	if (len == 0 || len + 2 > sizeof(g_cache_root))
		return;
	strcpy(g_cache_root, resolved);
	if (g_cache_root[len - 1] != '/') {
		g_cache_root[len]     = '/';
		g_cache_root[len + 1] = '\0';
	}
}

/* The app's soundtrack setting for SyncTERM audio. */
void
native_set_apc_audio_enabled(bool enabled)
{
	audio_apc_set_enabled(enabled);
}

/* Pulls `frames` of the SyncTERM audio mix (S16 stereo 44.1 kHz, interleaved). Returns how many leading frames
 * had audio; the rest of the buffer is silence. Called on the audio render thread. */
int32_t
native_apc_audio_pull(int16_t *out, int32_t frames)
{
	if (out == NULL || frames <= 0)
		return 0;
	return (int32_t)xp_mixer_pull(out, (size_t)frames);
}
