/*
 * WebSocket (RFC 6455) connection provider.
 *
 * Structure mirrors telnets.c / rlogin.c: an input thread pulls bytes off the
 * transport, de-frames them and feeds conn_inbuf; an output thread drains
 * conn_outbuf into masked binary frames.  The transport is either a bare
 * socket (ws://) or a cryptlib TLS session on top of it (wss://).
 *
 * The payload is handed to the telnet interpreter, so telnet option
 * negotiation works exactly as it does for a direct telnet connection.  This
 * matches Synchronet's WebSocket service and WebSockify wrappers around a
 * telnet port, which is what BBSes advertising "secure websocket" run.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#include "bbslist.h"
#include "conn.h"
#include "conn_telnet.h"
#include "conn_websocket.h"
#include "gen_defs.h"
#include "genwrap.h"
#include "sockwrap.h"
#include "telnet_io.h"
#include "threadwrap.h"
#include "sha1.h"
#include "base64.h"

#ifndef WITHOUT_CRYPTLIB
 #include "cryptlib.h"
#endif

#ifdef _MSC_VER
 #pragma warning(disable : 4244 4267 4018)
#endif

/* --------------------------------------------------------------------- */
/* Tunables                                                              */
/* --------------------------------------------------------------------- */

#define WS_HANDSHAKE_TIMEOUT_MS 15000   /* whole HTTP upgrade exchange     */
#define WS_MAX_HTTP_RESPONSE    8192    /* cap on upgrade response headers */
#define WS_MAX_FRAME_PAYLOAD    (1024 * 1024) /* refuse absurd frames      */
#define WS_GUID                 "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

enum {
	WS_OP_CONTINUATION = 0x0,
	WS_OP_TEXT         = 0x1,
	WS_OP_BINARY       = 0x2,
	WS_OP_CLOSE        = 0x8,
	WS_OP_PING         = 0x9,
	WS_OP_PONG         = 0xA
};

/* --------------------------------------------------------------------- */
/* State                                                                 */
/* --------------------------------------------------------------------- */

void (*websocket_log_cb)(const char *msg) = NULL;
char websocket_path[256] = "/";

static SOCKET          ws_sock = INVALID_SOCKET;
static bool            ws_secure = false;
static pthread_mutex_t ws_tx_mutex;     /* serialises frame writes (output thread + pong) */
#ifndef WITHOUT_CRYPTLIB
static CRYPT_SESSION   ws_session = -1;
static pthread_mutex_t ws_crypt_mutex;  /* serialises cryptlib calls */
#endif

/* Receive-side reassembly buffer (raw bytes off the transport, frames parsed in place) */
static unsigned char  *ws_rxbuf = NULL;
static size_t          ws_rxcap = 0;
static size_t          ws_rxlen = 0;

static void
ws_log(const char *fmt, ...)
{
	char    buf[512];
	va_list ap;

	if (websocket_log_cb == NULL)
		return;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	buf[sizeof(buf) - 1] = '\0';
	websocket_log_cb(buf);
}

/* --------------------------------------------------------------------- */
/* Transport: plain socket or cryptlib TLS                               */
/* --------------------------------------------------------------------- */

/*
 * Returns >0 bytes read, 0 if nothing arrived within timeout_ms,
 * -1 if the connection is gone.
 */
static int
ws_raw_recv(void *buf, int len, int timeout_ms)
{
	bool data_avail = false;

	if (ws_sock == INVALID_SOCKET || len <= 0)
		return -1;
	if (!socket_check(ws_sock, &data_avail, NULL, timeout_ms))
		return -1;
	if (!data_avail)
		return 0;

#ifndef WITHOUT_CRYPTLIB
	if (ws_secure) {
		int copied = 0;
		int status;

		assert_pthread_mutex_lock(&ws_crypt_mutex);
		cryptFlushData(ws_session);
		status = cryptPopData(ws_session, buf, len, &copied);
		assert_pthread_mutex_unlock(&ws_crypt_mutex);
		if (status == CRYPT_ERROR_TIMEOUT)
			return copied;          /* socket activity without app data (rekey etc.) */
		if (cryptStatusError(status)) {
			if (status != CRYPT_ERROR_COMPLETE && status != CRYPT_ERROR_READ)
				ws_log("TLS receive error %d", status);
			return -1;
		}
		return copied;
	}
#endif
	{
		int rd = recv(ws_sock, buf, len, 0);
		return rd <= 0 ? -1 : rd;
	}
}

/* Blocks until every byte is on the wire (or the connection dies). 0 ok, -1 error. */
static int
ws_raw_send_all(const void *vbuf, size_t len)
{
	const unsigned char *buf = vbuf;
	size_t               sent = 0;

	if (ws_sock == INVALID_SOCKET)
		return -1;

#ifndef WITHOUT_CRYPTLIB
	if (ws_secure) {
		int rc = 0;

		assert_pthread_mutex_lock(&ws_crypt_mutex);
		while (sent < len && !conn_api.terminate) {
			int copied = 0;
			int status = cryptPushData(ws_session, buf + sent, (int)(len - sent), &copied);
			if (cryptStatusError(status)) {
				if (status != CRYPT_ERROR_COMPLETE && status != CRYPT_ERROR_WRITE)
					ws_log("TLS send error %d", status);
				rc = -1;
				break;
			}
			sent += copied;
		}
		if (rc == 0 && sent)
			cryptFlushData(ws_session);
		assert_pthread_mutex_unlock(&ws_crypt_mutex);
		return rc;
	}
#endif
	while (sent < len && !conn_api.terminate) {
		if (!socket_writable(ws_sock, 100))
			continue;
		{
			ssize_t ret = sendsocket(ws_sock, buf + sent, len - sent);
			if (ret <= 0)
				return -1;
			sent += ret;
		}
	}
	return sent == len ? 0 : -1;
}

/* --------------------------------------------------------------------- */
/* Framing                                                               */
/* --------------------------------------------------------------------- */

/*
 * Client-to-server frames MUST be masked (RFC 6455 §5.3).  Builds the header,
 * masks a copy of the payload and pushes the whole thing through the transport
 * under the tx mutex so a pong from the input thread can't interleave with an
 * output-thread data frame.
 */
static int
ws_send_frame(unsigned char opcode, const unsigned char *payload, size_t len)
{
	unsigned char  hdr[14];
	size_t         hlen = 0;
	unsigned char  mask[4];
	unsigned char *masked = NULL;
	int            rc;
	size_t         i;

	hdr[hlen++] = (unsigned char)(0x80 | (opcode & 0x0f));  /* FIN + opcode */
	if (len < 126) {
		hdr[hlen++] = (unsigned char)(0x80 | len);
	}
	else if (len <= 0xFFFF) {
		hdr[hlen++] = 0x80 | 126;
		hdr[hlen++] = (unsigned char)(len >> 8);
		hdr[hlen++] = (unsigned char)(len & 0xff);
	}
	else {
		hdr[hlen++] = 0x80 | 127;
		for (i = 0; i < 8; i++)
			hdr[hlen++] = (unsigned char)(((uint64_t)len >> (8 * (7 - i))) & 0xff);
	}
	for (i = 0; i < 4; i++)
		mask[i] = (unsigned char)xp_random(256);
	memcpy(&hdr[hlen], mask, 4);
	hlen += 4;

	if (len) {
		masked = malloc(len);
		if (masked == NULL)
			return -1;
		for (i = 0; i < len; i++)
			masked[i] = payload[i] ^ mask[i & 3];
	}

	assert_pthread_mutex_lock(&ws_tx_mutex);
	rc = ws_raw_send_all(hdr, hlen);
	if (rc == 0 && len)
		rc = ws_raw_send_all(masked, len);
	assert_pthread_mutex_unlock(&ws_tx_mutex);

	free(masked);
	return rc;
}

static bool
ws_rxbuf_reserve(size_t need)
{
	if (need <= ws_rxcap)
		return true;
	{
		size_t         ncap = ws_rxcap ? ws_rxcap : BUFFER_SIZE;
		unsigned char *nbuf;

		while (ncap < need)
			ncap *= 2;
		nbuf = realloc(ws_rxbuf, ncap);
		if (nbuf == NULL)
			return false;
		ws_rxbuf = nbuf;
		ws_rxcap = ncap;
	}
	return true;
}

/* Push de-framed application bytes into conn_inbuf, blocking as needed. */
static void
ws_deliver(const unsigned char *data, size_t len)
{
	size_t done = 0;

	while (done < len && !conn_api.terminate) {
		size_t put;

		assert_pthread_mutex_lock(&(conn_inbuf.mutex));
		conn_buf_wait_free(&conn_inbuf, 1, 1000);
		put = conn_buf_put(&conn_inbuf, data + done, len - done);
		assert_pthread_mutex_unlock(&(conn_inbuf.mutex));
		done += put;
	}
}

/*
 * Parse as many complete frames as ws_rxbuf holds.  Returns false when the
 * peer closed or a protocol error was hit.
 */
static bool
ws_process_frames(void)
{
	for (;;) {
		unsigned char *p = ws_rxbuf;
		size_t         avail = ws_rxlen;
		size_t         hlen;
		size_t         plen;
		bool           masked;
		unsigned char  opcode;
		unsigned char *payload;

		if (avail < 2)
			return true;
		opcode = p[0] & 0x0f;
		masked = (p[1] & 0x80) != 0;
		plen = p[1] & 0x7f;
		hlen = 2;
		if (plen == 126) {
			if (avail < 4)
				return true;
			plen = ((size_t)p[2] << 8) | p[3];
			hlen = 4;
		}
		else if (plen == 127) {
			uint64_t l = 0;
			int      i;

			if (avail < 10)
				return true;
			for (i = 0; i < 8; i++)
				l = (l << 8) | p[2 + i];
			if (l > WS_MAX_FRAME_PAYLOAD) {
				ws_log("Frame too large (%llu bytes), closing", (unsigned long long)l);
				return false;
			}
			plen = (size_t)l;
			hlen = 10;
		}
		if (plen > WS_MAX_FRAME_PAYLOAD) {
			ws_log("Frame too large (%zu bytes), closing", plen);
			return false;
		}
		if (masked)
			hlen += 4;
		if (avail < hlen + plen) {
			if (!ws_rxbuf_reserve(hlen + plen))
				return false;
			return true;                    /* wait for the rest */
		}

		payload = p + hlen;
		if (masked) {
			const unsigned char *mask = p + hlen - 4;
			size_t               i;
			for (i = 0; i < plen; i++)
				payload[i] ^= mask[i & 3];
		}

		switch (opcode) {
			case WS_OP_CONTINUATION:
			case WS_OP_TEXT:
			case WS_OP_BINARY:
				ws_deliver(payload, plen);
				break;
			case WS_OP_PING:
				ws_send_frame(WS_OP_PONG, payload, plen);
				break;
			case WS_OP_PONG:
				break;
			case WS_OP_CLOSE:
				ws_log("Server sent CLOSE");
				ws_send_frame(WS_OP_CLOSE, payload, plen > 2 ? 2 : plen);
				return false;
			default:
				ws_log("Unknown opcode 0x%x, closing", opcode);
				return false;
		}

		/* consume the frame */
		ws_rxlen -= hlen + plen;
		if (ws_rxlen)
			memmove(ws_rxbuf, p + hlen + plen, ws_rxlen);
	}
}

/* --------------------------------------------------------------------- */
/* HTTP upgrade handshake                                                */
/* --------------------------------------------------------------------- */

static void
ws_expected_accept(const char *key, char *out, size_t outlen)
{
	char    cat[128];
	uint8_t digest[SHA1_DIGEST_SIZE];

	snprintf(cat, sizeof(cat), "%s%s", key, WS_GUID);
	SHA1_calc(digest, cat, strlen(cat));
	b64_encode(out, outlen, (const char *)digest, SHA1_DIGEST_SIZE);
}

/* Case-insensitive header lookup within a CRLF-delimited block. Copies the value. */
static bool
ws_find_header(const char *hdrs, const char *name, char *val, size_t vallen)
{
	size_t      nlen = strlen(name);
	const char *line = hdrs;

	while (line && *line) {
		const char *eol = strstr(line, "\r\n");
		size_t      llen = eol ? (size_t)(eol - line) : strlen(line);

		if (llen > nlen + 1 && strnicmp(line, name, nlen) == 0 && line[nlen] == ':') {
			const char *v = line + nlen + 1;
			size_t      vl;

			while (*v == ' ' || *v == '\t')
				v++;
			vl = llen - (v - line);
			while (vl && (v[vl - 1] == ' ' || v[vl - 1] == '\t'))
				vl--;
			if (vl >= vallen)
				vl = vallen - 1;
			memcpy(val, v, vl);
			val[vl] = '\0';
			return true;
		}
		line = eol ? eol + 2 : NULL;
	}
	return false;
}

static int
ws_handshake(struct bbslist *bbs)
{
	unsigned char nonce[16];
	char          key[64];
	char          expected[64];
	char          got[128];
	char          req[1024];
	char          resp[WS_MAX_HTTP_RESPONSE + 1];
	size_t        rlen = 0;
	char         *end;
	int           i;
	clock_t       start;

	for (i = 0; i < (int)sizeof(nonce); i++)
		nonce[i] = (unsigned char)xp_random(256);
	b64_encode(key, sizeof(key), (const char *)nonce, sizeof(nonce));
	ws_expected_accept(key, expected, sizeof(expected));

	snprintf(req, sizeof(req),
	    "GET %s HTTP/1.1\r\n"
	    "Host: %s:%u\r\n"
	    "Upgrade: websocket\r\n"
	    "Connection: Upgrade\r\n"
	    "Sec-WebSocket-Key: %s\r\n"
	    "Sec-WebSocket-Version: 13\r\n"
	    "User-Agent: TERMinator\r\n"
	    "\r\n",
	    websocket_path[0] ? websocket_path : "/",
	    bbs->addr, (unsigned)bbs->port, key);

	ws_log("Upgrade request: GET %s (host %s:%u)", websocket_path, bbs->addr, (unsigned)bbs->port);
	if (ws_raw_send_all(req, strlen(req)) != 0) {
		ws_log("Failed to send upgrade request");
		return -1;
	}

	/* Read until the end of headers, or timeout */
	start = msclock();
	for (;;) {
		int rd;

		if (rlen >= WS_MAX_HTTP_RESPONSE) {
			ws_log("Upgrade response too large");
			return -1;
		}
		resp[rlen] = '\0';
		end = strstr(resp, "\r\n\r\n");
		if (end != NULL)
			break;
		if ((msclock() - start) > (WS_HANDSHAKE_TIMEOUT_MS * MSCLOCKS_PER_SEC / 1000)) {
			ws_log("Timed out waiting for upgrade response");
			return -1;
		}
		rd = ws_raw_recv(resp + rlen, (int)(WS_MAX_HTTP_RESPONSE - rlen), 100);
		if (rd < 0) {
			ws_log("Connection dropped during upgrade");
			return -1;
		}
		rlen += rd;
	}

	/* Status line */
	if (strncmp(resp, "HTTP/1.1 101", 12) != 0 && strncmp(resp, "HTTP/1.0 101", 12) != 0) {
		char line[128];
		char *eol = strstr(resp, "\r\n");
		size_t ll = eol ? (size_t)(eol - resp) : strlen(resp);
		if (ll >= sizeof(line))
			ll = sizeof(line) - 1;
		memcpy(line, resp, ll);
		line[ll] = '\0';
		ws_log("Upgrade refused: %s", line);
		return -1;
	}

	if (!ws_find_header(resp, "Sec-WebSocket-Accept", got, sizeof(got))) {
		ws_log("No Sec-WebSocket-Accept in response");
		return -1;
	}
	if (strcmp(got, expected) != 0) {
		ws_log("Bad Sec-WebSocket-Accept (got %s, expected %s)", got, expected);
		return -1;
	}

	/* Anything after the blank line is already frame data */
	{
		size_t consumed = (end - resp) + 4;
		size_t leftover = rlen - consumed;

		if (leftover) {
			if (!ws_rxbuf_reserve(leftover))
				return -1;
			memcpy(ws_rxbuf, resp + consumed, leftover);
			ws_rxlen = leftover;
		}
	}
	ws_log("WebSocket established (%s)", ws_secure ? "wss" : "ws");
	return 0;
}

/* --------------------------------------------------------------------- */
/* Threads                                                               */
/* --------------------------------------------------------------------- */

static void
websocket_input_thread(void *args)
{
	(void)args;
	SetThreadName("WebSocket Input");
	conn_api.input_thread_running = 1;

	/* Frames that arrived with the handshake response */
	if (ws_rxlen && !ws_process_frames())
		conn_api.terminate = true;

	while (!conn_api.terminate) {
		int rd;

		if (!ws_rxbuf_reserve(ws_rxlen + BUFFER_SIZE))
			break;
		rd = ws_raw_recv(ws_rxbuf + ws_rxlen, (int)(ws_rxcap - ws_rxlen), 100);
		if (rd < 0)
			break;
		if (rd == 0)
			continue;
		ws_rxlen += rd;
		if (!ws_process_frames())
			break;
	}
	conn_api.terminate = true;
	if (ws_sock != INVALID_SOCKET)
		shutdown(ws_sock, SHUT_RDWR);
	conn_api.input_thread_running = 2;
}

static void
websocket_output_thread(void *args)
{
	(void)args;
	SetThreadName("WebSocket Output");
	conn_api.output_thread_running = 1;
	while (!conn_api.terminate) {
		size_t wr;

		assert_pthread_mutex_lock(&(conn_outbuf.mutex));
		wr = conn_buf_wait_bytes(&conn_outbuf, 1, 100);
		if (wr) {
			wr = conn_buf_get(&conn_outbuf, conn_api.wr_buf, conn_api.wr_buf_size);
			assert_pthread_mutex_unlock(&(conn_outbuf.mutex));
			if (ws_send_frame(WS_OP_BINARY, conn_api.wr_buf, wr) != 0)
				break;
		}
		else {
			assert_pthread_mutex_unlock(&(conn_outbuf.mutex));
		}
	}
	conn_api.terminate = true;
	if (ws_sock != INVALID_SOCKET)
		shutdown(ws_sock, SHUT_RDWR);
	conn_api.output_thread_running = 2;
}

/* --------------------------------------------------------------------- */
/* Connect / close                                                       */
/* --------------------------------------------------------------------- */

static void
ws_teardown_transport(void)
{
#ifndef WITHOUT_CRYPTLIB
	if (ws_secure && ws_session != -1) {
		cryptDestroySession(ws_session);
		ws_session = -1;
	}
#endif
	if (ws_sock != INVALID_SOCKET) {
		closesocket(ws_sock);
		ws_sock = INVALID_SOCKET;
	}
	FREE_AND_NULL(ws_rxbuf);
	ws_rxcap = 0;
	ws_rxlen = 0;
}

int
websocket_connect(struct bbslist *bbs)
{
	int off = 1;

	ws_secure = (bbs->conn_type == CONN_TYPE_WEBSOCKETS);
	ws_rxlen = 0;
	assert_pthread_mutex_init(&ws_tx_mutex, NULL);
#ifndef WITHOUT_CRYPTLIB
	assert_pthread_mutex_init(&ws_crypt_mutex, NULL);
	ws_session = -1;
#else
	if (ws_secure) {
		ws_log("Secure WebSocket requested but cryptlib is not available");
		conn_api.terminate = true;
		return -1;
	}
#endif

	ws_sock = conn_socket_connect(bbs, true);
	if (ws_sock == INVALID_SOCKET) {
		conn_api.terminate = true;
		return -1;
	}
	if (setsockopt(ws_sock, IPPROTO_TCP, TCP_NODELAY, (char *)&off, sizeof(off)))
		ws_log("setsockopt(TCP_NODELAY) failed");

#ifndef WITHOUT_CRYPTLIB
	if (ws_secure) {
		int status;

		status = cryptCreateSession(&ws_session, CRYPT_UNUSED, CRYPT_SESSION_SSL);
		if (cryptStatusError(status)) {
			ws_log("Error %d creating TLS session", status);
			ws_session = -1;
			goto fail;
		}
		status = cryptSetAttribute(ws_session, CRYPT_SESSINFO_NETWORKSOCKET, ws_sock);
		if (cryptStatusError(status)) {
			ws_log("Error %d passing socket to TLS session", status);
			goto fail;
		}
		cryptSetAttribute(ws_session, CRYPT_OPTION_NET_READTIMEOUT, 1);
		cryptSetAttributeString(ws_session, CRYPT_SESSINFO_SERVER_NAME, bbs->addr, strlen(bbs->addr));
		status = cryptSetAttribute(ws_session, CRYPT_SESSINFO_ACTIVE, 1);
		if (cryptStatusError(status)) {
			ws_log("Error %d activating TLS session", status);
			goto fail;
		}
		status = cryptSetAttribute(ws_session, CRYPT_PROPERTY_OWNER, CRYPT_UNUSED);
		if (cryptStatusError(status)) {
			ws_log("Error %d clearing TLS session ownership", status);
			goto fail;
		}
		ws_log("TLS handshake complete");
	}
#endif

	if (ws_handshake(bbs) != 0)
		goto fail;

	if (!create_conn_buf(&conn_inbuf, BUFFER_SIZE))
		goto fail;
	if (!create_conn_buf(&conn_outbuf, BUFFER_SIZE)) {
		destroy_conn_buf(&conn_inbuf);
		goto fail;
	}
	conn_api.rd_buf = (unsigned char *)malloc(BUFFER_SIZE);
	conn_api.wr_buf = (unsigned char *)malloc(BUFFER_SIZE);
	if (!conn_api.rd_buf || !conn_api.wr_buf) {
		FREE_AND_NULL(conn_api.rd_buf);
		FREE_AND_NULL(conn_api.wr_buf);
		destroy_conn_buf(&conn_inbuf);
		destroy_conn_buf(&conn_outbuf);
		goto fail;
	}
	conn_api.rd_buf_size = BUFFER_SIZE;
	conn_api.wr_buf_size = BUFFER_SIZE;

	/* The payload is a telnet stream: same negotiation as a direct telnet session */
	memset(telnet_local_option, 0, sizeof(telnet_local_option));
	memset(telnet_remote_option, 0, sizeof(telnet_remote_option));
	conn_api.rx_parse_cb = telnet_rx_parse_cb;
	conn_api.tx_parse_cb = telnet_tx_parse_cb;
	telnet_deferred = bbs->defer_telnet_negotiation;
	telnet_no_binary = bbs->telnet_no_binary;
	strlcpy(term_name, get_emulation_str(bbs), sizeof(term_name));

	_beginthread(websocket_output_thread, 0, NULL);
	_beginthread(websocket_input_thread, 0, NULL);

	if (!telnet_deferred)
		send_initial_state();

	return 0;

fail:
	conn_api.terminate = true;
	ws_teardown_transport();
	return -1;
}

int
websocket_close(void)
{
	char garbage[1024];

	conn_api.terminate = true;
#ifndef WITHOUT_CRYPTLIB
	if (ws_secure && ws_session != -1)
		cryptSetAttribute(ws_session, CRYPT_SESSINFO_ACTIVE, 0);
#endif
	if (ws_sock != INVALID_SOCKET)
		shutdown(ws_sock, SHUT_RDWR);
	while (conn_api.input_thread_running == 1 || conn_api.output_thread_running == 1) {
		conn_recv_upto(garbage, sizeof(garbage), 0);
		SLEEP(1);
	}
	ws_teardown_transport();
	destroy_conn_buf(&conn_inbuf);
	destroy_conn_buf(&conn_outbuf);
	FREE_AND_NULL(conn_api.rd_buf);
	FREE_AND_NULL(conn_api.wr_buf);
	pthread_mutex_destroy(&ws_tx_mutex);
#ifndef WITHOUT_CRYPTLIB
	pthread_mutex_destroy(&ws_crypt_mutex);
#endif
	return 0;
}
