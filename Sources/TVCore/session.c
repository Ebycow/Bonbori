// SPDX-License-Identifier: GPL-2.0-or-later
// BonDriverProxy(Ex) protocol client and pipeline glue.
//
// Wire format (see BonDriverProxyEx/inc/BdpPacket.h):
//   [0xFF][cmd][opt][0][body length (BE32)] body...
// TS is pushed asynchronously by the server as eGetTsStream packets:
//   [size (BE32)][signal level (float bits, BE32)][TS bytes]
#include "internal.h"
#include "TVCore.h"

#include <CoreFoundation/CoreFoundation.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <libavutil/log.h>

enum {
    eSelectBonDriver = 0,
    eCreateBonDriver,
    eOpenTuner,
    eCloseTuner,
    eSetChannel1,
    eGetSignalLevel,
    eWaitTsStream,
    eGetReadyCount,
    eGetTsStream,
    ePurgeTsStream,
    eRelease,
    eGetTunerName,
    eIsTunerOpening,
    eEnumTuningSpace,
    eEnumChannelName,
    eSetChannel2,
    eGetCurSpace,
    eGetCurChannel,
    eGetTotalDeviceNum,
    eGetActiveDeviceNum,
    eSetLnbPower,
    eGetClientInfo,
};

struct tv_session {
    tv_callbacks cb;
    pthread_mutex_t api_mtx;

    int fd;
    atomic_bool open;
    atomic_bool closing;
    pthread_t rx;
    bool rx_running;

    pthread_mutex_t mtx;
    pthread_cond_t cond;
    int wait_cmd;
    bool resp_ready;
    uint8_t *resp;
    uint32_t resp_len;
    bool conn_closed;

    atomic_bool discard_ts;
    atomic_bool tuning;
    int tune_sid;
    int64_t tune_start;
    atomic_uint gen;
    atomic_int req_sid;
    atomic_int req_audio;
    atomic_int opts;

    tv_demux *dmx;
    tv_decoder *vdec, *adec;
    tv_decoder *tapdec;  // second audio decoder for on_tap_audio
    tv_timeline *timeline;
    atomic_bool tap_on;

    // Output delay line: PES and PCR wait here before reaching the decoders / on_clock.
    atomic_int delay_ms;
    pthread_mutex_t dl_mtx;
    pthread_cond_t dl_cond;
    struct dl_item *dl_head, *dl_tail;
    size_t dl_bytes;
    bool dl_quit;
    pthread_t dl_thread;

    float signal;
    uint64_t bytes;

    pthread_mutex_t rec_mtx;
    FILE *rec;
    uint64_t rec_bytes;
    int64_t last_status;
    int64_t last_clock;
};

// ----------------------------------------------------------------- output delay line
enum { DL_PCR = 2 };  // besides PES_VIDEO / PES_AUDIO

typedef struct dl_item {
    struct dl_item *next;
    int64_t due;  // now_ms() time to release
    int kind, stream_type;
    int64_t pts, dts;  // PCR in pts for DL_PCR
    uint32_t gen;
    size_t len;
    uint8_t data[];
} dl_item;

#define DL_MAX_BYTES (96u * 1024 * 1024)

static void dl_clear_locked(tv_session *s)
{
    while (s->dl_head) {
        dl_item *o = s->dl_head;
        s->dl_head = o->next;
        free(o);
    }
    s->dl_tail = NULL;
    s->dl_bytes = 0;
}

static void dl_push(tv_session *s, int delay, int kind, int st, const uint8_t *data, size_t len, int64_t pts,
                    int64_t dts, uint32_t gen)
{
    dl_item *it = malloc(sizeof(dl_item) + len);
    it->next = NULL;
    it->due = now_ms() + delay;
    it->kind = kind;
    it->stream_type = st;
    it->pts = pts;
    it->dts = dts;
    it->gen = gen;
    it->len = len;
    if (len)
        memcpy(it->data, data, len);
    pthread_mutex_lock(&s->dl_mtx);
    if (s->dl_tail)
        s->dl_tail->next = it;
    else
        s->dl_head = it;
    s->dl_tail = it;
    s->dl_bytes += len;
    while (s->dl_bytes > DL_MAX_BYTES && s->dl_head != it) {
        dl_item *o = s->dl_head;
        s->dl_head = o->next;
        s->dl_bytes -= o->len;
        free(o);
    }
    pthread_cond_signal(&s->dl_cond);
    pthread_mutex_unlock(&s->dl_mtx);
}

static void deliver(tv_session *s, int kind, int st, const uint8_t *data, size_t len, int64_t pts, int64_t dts,
                    uint32_t gen)
{
    if (kind == DL_PCR) {
        int64_t off;
        int ppm;
        tv_timeline_get(s->timeline, gen, &off, &ppm);
        if (s->cb.on_clock)
            s->cb.on_clock(s->cb.ctx, pts + off, gen);
        return;
    }
    tv_decoder_push(kind == PES_VIDEO ? s->vdec : s->adec, st, data, len, pts, dts, gen);
}

static void *dl_thread(void *arg)
{
    tv_session *s = arg;
    pthread_setname_np("tv.delay");
    pthread_mutex_lock(&s->dl_mtx);
    for (;;) {
        while (!s->dl_quit && !s->dl_head)
            pthread_cond_wait(&s->dl_cond, &s->dl_mtx);
        if (s->dl_quit)
            break;
        int64_t wait = s->dl_head->due - now_ms();
        if (wait > 0) {
            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            ts.tv_sec += wait / 1000;
            ts.tv_nsec += (long)(wait % 1000) * 1000000L;
            if (ts.tv_nsec >= 1000000000L) {
                ts.tv_sec++;
                ts.tv_nsec -= 1000000000L;
            }
            pthread_cond_timedwait(&s->dl_cond, &s->dl_mtx, &ts);
            continue;
        }
        dl_item *it = s->dl_head;
        s->dl_head = it->next;
        if (!s->dl_head)
            s->dl_tail = NULL;
        s->dl_bytes -= it->len;
        pthread_mutex_unlock(&s->dl_mtx);
        deliver(s, it->kind, it->stream_type, it->data, it->len, it->pts, it->dts, it->gen);
        free(it);
        pthread_mutex_lock(&s->dl_mtx);
    }
    pthread_mutex_unlock(&s->dl_mtx);
    return NULL;
}

// ----------------------------------------------------------------- pipeline callbacks
static void on_pes(void *ctx, int kind, int st, const uint8_t *data, size_t len, int64_t pts, int64_t dts)
{
    tv_session *s = ctx;
    uint32_t gen = atomic_load(&s->gen);
    if (kind == PES_AUDIO && atomic_load(&s->tap_on))
        tv_decoder_push(s->tapdec, st, data, len, pts, dts, gen);
    int delay = atomic_load(&s->delay_ms);
    if (delay > 0)
        dl_push(s, delay, kind, st, data, len, pts, dts, gen);
    else
        deliver(s, kind, st, data, len, pts, dts, gen);
}

static void on_pcr(void *ctx, int64_t pcr)
{
    tv_session *s = ctx;
    if (s->last_clock != TV_NOPTS && pcr >= s->last_clock && pcr - s->last_clock < 9000)
        return;
    s->last_clock = pcr;
    int delay = atomic_load(&s->delay_ms);
    if (delay > 0)
        dl_push(s, delay, DL_PCR, 0, NULL, 0, pcr, TV_NOPTS, atomic_load(&s->gen));
    else
        deliver(s, DL_PCR, 0, NULL, 0, pcr, TV_NOPTS, atomic_load(&s->gen));
}

static void on_dmx_event(void *ctx, int type, const char *json)
{
    tv_session *s = ctx;
    if (s->cb.on_event)
        s->cb.on_event(s->cb.ctx, type, json);
}

static uint32_t bump_generation(tv_session *s)
{
    uint32_t g = atomic_fetch_add(&s->gen, 1) + 1;
    pthread_mutex_lock(&s->dl_mtx);
    dl_clear_locked(s);
    pthread_mutex_unlock(&s->dl_mtx);
    tv_decoder_flush(s->vdec, g);
    tv_decoder_flush(s->adec, g);
    tv_decoder_flush(s->tapdec, g);
    s->last_clock = TV_NOPTS;
    return g;
}

static void on_service_switch(void *ctx, int sid)
{
    (void)sid;
    bump_generation((tv_session *)ctx);
}

static void on_dec_video(void *ctx, void *sb, uint32_t gen)
{
    tv_session *s = ctx;
    if (s->cb.on_video)
        s->cb.on_video(s->cb.ctx, (CMSampleBufferRef)sb, gen);
}

static void on_dec_audio(void *ctx, void *sb, uint32_t gen)
{
    tv_session *s = ctx;
    if (s->cb.on_audio)
        s->cb.on_audio(s->cb.ctx, (CMSampleBufferRef)sb, gen);
}

static void on_dec_tap_audio(void *ctx, void *sb, uint32_t gen)
{
    tv_session *s = ctx;
    if (s->cb.on_tap_audio)
        s->cb.on_tap_audio(s->cb.ctx, (CMSampleBufferRef)sb, gen);
}

static void on_dec_info(void *ctx, int kind, const char *json)
{
    (void)kind;
    tv_session *s = ctx;
    if (s->cb.on_event)
        s->cb.on_event(s->cb.ctx, TV_EV_FORMAT, json);
}

static void emit_json(tv_session *s, int type, const char *json)
{
    if (s->cb.on_event)
        s->cb.on_event(s->cb.ctx, type, json);
}

// ----------------------------------------------------------------- lifecycle
tv_session *tv_session_create(tv_callbacks cb)
{
    av_log_set_level(getenv("TV_FFMPEG_LOG") ? AV_LOG_VERBOSE : AV_LOG_QUIET);
    tv_session *s = calloc(1, sizeof(*s));
    s->cb = cb;
    s->fd = -1;
    s->wait_cmd = -1;
    s->last_clock = TV_NOPTS;
    atomic_init(&s->req_sid, -1);
    atomic_init(&s->req_audio, -1);
    atomic_init(&s->opts, 1);
    pthread_mutex_init(&s->api_mtx, NULL);
    pthread_mutex_init(&s->mtx, NULL);
    pthread_mutex_init(&s->rec_mtx, NULL);
    pthread_cond_init(&s->cond, NULL);
    tv_demux_cb dcb = {s, on_pes, on_pcr, on_dmx_event, on_service_switch};
    s->dmx = tv_demux_create(dcb);
    tv_decoder_cb vcb = {s, on_dec_video, on_dec_audio, on_dec_info};
    s->vdec = tv_decoder_create(PES_VIDEO, vcb);
    s->adec = tv_decoder_create(PES_AUDIO, vcb);
    tv_decoder_cb tcb = {s, NULL, on_dec_tap_audio, NULL};
    s->tapdec = tv_decoder_create(PES_AUDIO, tcb);
    s->timeline = tv_timeline_create();
    tv_decoder_set_timeline(s->vdec, s->timeline, false);
    tv_decoder_set_timeline(s->adec, s->timeline, true);
    tv_decoder_set_timeline(s->tapdec, s->timeline, false);
    pthread_mutex_init(&s->dl_mtx, NULL);
    pthread_cond_init(&s->dl_cond, NULL);
    pthread_create(&s->dl_thread, NULL, dl_thread, s);
    return s;
}

void tv_session_destroy(tv_session *s)
{
    if (!s)
        return;
    tv_session_close(s);
    tv_session_record_stop(s);
    pthread_mutex_destroy(&s->rec_mtx);
    pthread_mutex_lock(&s->dl_mtx);
    s->dl_quit = true;
    dl_clear_locked(s);
    pthread_cond_signal(&s->dl_cond);
    pthread_mutex_unlock(&s->dl_mtx);
    pthread_join(s->dl_thread, NULL);
    pthread_mutex_destroy(&s->dl_mtx);
    pthread_cond_destroy(&s->dl_cond);
    tv_decoder_destroy(s->vdec);
    tv_decoder_destroy(s->adec);
    tv_decoder_destroy(s->tapdec);
    tv_timeline_destroy(s->timeline);
    tv_demux_destroy(s->dmx);
    free(s->resp);
    pthread_mutex_destroy(&s->api_mtx);
    pthread_mutex_destroy(&s->mtx);
    pthread_cond_destroy(&s->cond);
    free(s);
}

uint32_t tv_session_generation(tv_session *s)
{
    return atomic_load(&s->gen);
}

int tv_session_record_start(tv_session *s, const char *path)
{
    FILE *f = fopen(path, "wb");
    if (!f)
        return -1;
    setvbuf(f, NULL, _IOFBF, 4 * 1024 * 1024);
    pthread_mutex_lock(&s->rec_mtx);
    if (s->rec)
        fclose(s->rec);
    s->rec = f;
    s->rec_bytes = 0;
    pthread_mutex_unlock(&s->rec_mtx);
    return 0;
}

uint64_t tv_session_record_stop(tv_session *s)
{
    pthread_mutex_lock(&s->rec_mtx);
    uint64_t n = s->rec_bytes;
    if (s->rec)
        fclose(s->rec);
    s->rec = NULL;
    pthread_mutex_unlock(&s->rec_mtx);
    return n;
}

bool tv_session_is_recording(tv_session *s)
{
    pthread_mutex_lock(&s->rec_mtx);
    bool r = s->rec != NULL;
    pthread_mutex_unlock(&s->rec_mtx);
    return r;
}

float tv_session_signal_level(tv_session *s)
{
    return s->signal;
}

bool tv_session_is_open(tv_session *s)
{
    return atomic_load(&s->open);
}

// ----------------------------------------------------------------- socket I/O
static bool write_all(int fd, const void *buf, size_t n)
{
    const uint8_t *p = buf;
    while (n > 0) {
        ssize_t w = send(fd, p, n, 0);
        if (w < 0) {
            if (errno == EINTR)
                continue;
            return false;
        }
        p += w;
        n -= (size_t)w;
    }
    return true;
}

static bool read_all(int fd, void *buf, size_t n)
{
    uint8_t *p = buf;
    while (n > 0) {
        ssize_t r = recv(fd, p, n, 0);
        if (r < 0 && errno == EINTR)
            continue;
        if (r <= 0)
            return false;
        p += r;
        n -= (size_t)r;
    }
    return true;
}

static bool send_cmd(tv_session *s, int cmd, const void *body, uint32_t len, uint8_t opt)
{
    uint8_t hdr[8] = {0xFF, (uint8_t)cmd, opt, 0};
    uint32_t be = htonl(len);
    memcpy(hdr + 4, &be, 4);
    uint8_t *buf = malloc(8 + len);
    memcpy(buf, hdr, 8);
    if (len)
        memcpy(buf + 8, body, len);
    bool ok = write_all(s->fd, buf, 8 + len);
    free(buf);
    return ok;
}

// Sends a command and waits for the response with the same command id.
// Returns malloc'ed body (caller frees) or NULL on timeout / disconnect.
static uint8_t *call(tv_session *s, int cmd, const void *body, uint32_t len, uint8_t opt, int timeout_ms,
                     uint32_t *out_len)
{
    pthread_mutex_lock(&s->mtx);
    if (s->conn_closed) {
        pthread_mutex_unlock(&s->mtx);
        return NULL;
    }
    s->wait_cmd = cmd;
    s->resp_ready = false;
    free(s->resp);
    s->resp = NULL;
    pthread_mutex_unlock(&s->mtx);

    if (!send_cmd(s, cmd, body, len, opt))
        return NULL;

    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += timeout_ms / 1000;
    ts.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
    if (ts.tv_nsec >= 1000000000L) {
        ts.tv_sec++;
        ts.tv_nsec -= 1000000000L;
    }
    pthread_mutex_lock(&s->mtx);
    while (!s->resp_ready && !s->conn_closed) {
        if (pthread_cond_timedwait(&s->cond, &s->mtx, &ts) == ETIMEDOUT)
            break;
    }
    uint8_t *r = NULL;
    if (s->resp_ready) {
        r = s->resp;
        s->resp = NULL;
        if (out_len)
            *out_len = s->resp_len;
    }
    s->wait_cmd = -1;
    s->resp_ready = false;
    pthread_mutex_unlock(&s->mtx);
    return r;
}

// ----------------------------------------------------------------- receive thread
static void apply_requests(tv_session *s)
{
    int sid = atomic_exchange(&s->req_sid, -1);
    if (sid >= 0)
        tv_demux_select_service(s->dmx, sid);
    int a = atomic_exchange(&s->req_audio, -1);
    if (a >= 0)
        tv_demux_select_audio(s->dmx, a);
}

static void status_tick(tv_session *s)
{
    int64_t now = now_ms();
    if (s->last_status == 0) {
        s->last_status = now;
        return;
    }
    int64_t el = now - s->last_status;
    if (el < 1000)
        return;
    tv_demux_stats st;
    tv_demux_get_stats(s->dmx, &st);
    char buf[384];
    snprintf(buf, sizeof(buf),
             "{\"signal\":%.2f,\"bitrate\":%.2f,\"packets\":%llu,\"scrambled\":%llu,\"drops\":%llu,\"errors\":%llu,"
             "\"vqueue\":%d,\"aqueue\":%d}",
             s->signal, (double)s->bytes * 8.0 / (double)el / 1000.0, (unsigned long long)st.packets,
             (unsigned long long)st.scrambled, (unsigned long long)st.drops, (unsigned long long)st.errors,
             tv_decoder_queue_len(s->vdec), tv_decoder_queue_len(s->adec));
    emit_json(s, TV_EV_STATUS, buf);
    s->bytes = 0;
    s->last_status = now;
}

static void *rx_thread(void *arg)
{
    tv_session *s = arg;
    pthread_setname_np("tv.network");
    size_t cap = 256 * 1024;
    uint8_t *body = malloc(cap);
    for (;;) {
        uint8_t hdr[8];
        if (!read_all(s->fd, hdr, 8))
            break;
        if (hdr[0] != 0xFF)
            break;
        int cmd = hdr[1];
        uint32_t len;
        memcpy(&len, hdr + 4, 4);
        len = ntohl(len);
        if (len > 64 * 1024 * 1024)
            break;
        if (len > cap) {
            cap = len;
            body = realloc(body, cap);
        }
        if (len && !read_all(s->fd, body, len))
            break;

        if (cmd == eGetTsStream) {
            if (len < 8)
                continue;
            uint32_t size, lv;
            memcpy(&size, body, 4);
            memcpy(&lv, body + 4, 4);
            size = ntohl(size);
            lv = ntohl(lv);
            memcpy(&s->signal, &lv, 4);
            if (size > len - 8)
                size = len - 8;
            if (!atomic_load(&s->discard_ts)) {
                apply_requests(s);
                tv_demux_feed(s->dmx, body + 8, size);
                s->bytes += size;
                pthread_mutex_lock(&s->rec_mtx);
                if (s->rec && fwrite(body + 8, 1, size, s->rec) == size)
                    s->rec_bytes += size;
                pthread_mutex_unlock(&s->rec_mtx);
            }
            status_tick(s);
            continue;
        }

        if (cmd == eSetChannel2 && atomic_load(&s->tuning)) {
            uint32_t res = 0xFF;
            if (len >= 4) {
                memcpy(&res, body, 4);
                res = ntohl(res);
            }
            if (res == 0) {
                // Everything after this response belongs to the new channel.
                atomic_store(&s->req_sid, -1);
                bump_generation(s);
                tv_demux_reset(s->dmx, s->tune_sid);
                s->bytes = 0;
                s->last_status = 0;
            }
            atomic_store(&s->discard_ts, false);
            char buf[128];
            snprintf(buf, sizeof(buf), "{\"ok\":%s,\"result\":%u,\"ms\":%lld,\"gen\":%u}", res == 0 ? "true" : "false",
                     res, (long long)(now_ms() - s->tune_start), atomic_load(&s->gen));
            emit_json(s, TV_EV_TUNED, buf);
        }

        pthread_mutex_lock(&s->mtx);
        if (s->wait_cmd == cmd) {
            free(s->resp);
            s->resp = malloc(len + 2);
            memcpy(s->resp, body, len);
            s->resp[len] = s->resp[len + 1] = 0;
            s->resp_len = len;
            s->resp_ready = true;
            pthread_cond_broadcast(&s->cond);
        }
        pthread_mutex_unlock(&s->mtx);
    }
    free(body);
    pthread_mutex_lock(&s->mtx);
    s->conn_closed = true;
    pthread_cond_broadcast(&s->cond);
    pthread_mutex_unlock(&s->mtx);
    atomic_store(&s->open, false);
    if (!atomic_load(&s->closing))
        emit_json(s, TV_EV_CLOSED, "{}");
    return NULL;
}

// ----------------------------------------------------------------- connect / open
static int connect_to(const char *host, int port, int timeout_ms)
{
    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", port);
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_family = AF_UNSPEC;
    if (getaddrinfo(host, portstr, &hints, &res) != 0)
        return -1;
    int fd = -1;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0)
            continue;
        int fl = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, fl | O_NONBLOCK);
        int r = connect(fd, ai->ai_addr, ai->ai_addrlen);
        if (r < 0 && errno == EINPROGRESS) {
            struct pollfd pfd = {fd, POLLOUT, 0};
            if (poll(&pfd, 1, timeout_ms) == 1) {
                int err = 0;
                socklen_t el = sizeof(err);
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el);
                r = err ? -1 : 0;
            } else {
                r = -1;
            }
        }
        if (r == 0) {
            fcntl(fd, F_SETFL, fl);
            break;
        }
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd >= 0) {
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        int rcv = 4 * 1024 * 1024;
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, sizeof(rcv));
    }
    return fd;
}

static void close_locked(tv_session *s)
{
    if (s->fd < 0)
        return;
    atomic_store(&s->closing, true);
    if (!s->conn_closed) {
        send_cmd(s, eCloseTuner, NULL, 0, 0);
        send_cmd(s, eRelease, NULL, 0, 0);
    }
    shutdown(s->fd, SHUT_RDWR);
    if (s->rx_running)
        pthread_join(s->rx, NULL);
    s->rx_running = false;
    close(s->fd);
    s->fd = -1;
    atomic_store(&s->open, false);
    bump_generation(s);
}

void tv_session_close(tv_session *s)
{
    pthread_mutex_lock(&s->api_mtx);
    close_locked(s);
    pthread_mutex_unlock(&s->api_mtx);
}

static bool call_bool(tv_session *s, int cmd, const void *body, uint32_t len)
{
    uint32_t rl = 0;
    uint8_t *r = call(s, cmd, body, len, 0, 10000, &rl);
    bool ok = r && rl >= 1 && r[0] != 0;
    free(r);
    return ok;
}

int tv_session_open(tv_session *s, const char *host, int port, const char *group)
{
    pthread_mutex_lock(&s->api_mtx);
    close_locked(s);
    int fd = connect_to(host, port, 3000);
    if (fd < 0) {
        pthread_mutex_unlock(&s->api_mtx);
        return -1;
    }
    s->fd = fd;
    s->conn_closed = false;
    atomic_store(&s->closing, false);
    atomic_store(&s->discard_ts, true);
    s->rx_running = pthread_create(&s->rx, NULL, rx_thread, s) == 0;

    int rc = 0;
    if (!call_bool(s, eSelectBonDriver, group, (uint32_t)strlen(group) + 1))
        rc = -2;
    else if (!call_bool(s, eCreateBonDriver, NULL, 0))
        rc = -3;
    else if (!call_bool(s, eOpenTuner, NULL, 0))
        rc = -4;
    if (rc != 0) {
        close_locked(s);
    } else {
        atomic_store(&s->open, true);
    }
    pthread_mutex_unlock(&s->api_mtx);
    return rc;
}

static char *utf16_to_utf8(const uint8_t *p, uint32_t len)
{
    uint32_t n = 0;
    while (n + 1 < len && (p[n] || p[n + 1]))
        n += 2;
    CFStringRef str = CFStringCreateWithBytes(NULL, p, n, kCFStringEncodingUTF16LE, false);
    if (!str)
        return NULL;
    CFIndex max = CFStringGetMaximumSizeForEncoding(CFStringGetLength(str), kCFStringEncodingUTF8) + 1;
    char *out = malloc((size_t)max);
    if (!CFStringGetCString(str, out, max, kCFStringEncodingUTF8)) {
        free(out);
        out = NULL;
    }
    CFRelease(str);
    return out;
}

char *tv_session_enum_space(tv_session *s, uint32_t space)
{
    pthread_mutex_lock(&s->api_mtx);
    uint32_t be = htonl(space), rl = 0;
    uint8_t *r = s->fd >= 0 ? call(s, eEnumTuningSpace, &be, 4, 0, 5000, &rl) : NULL;
    pthread_mutex_unlock(&s->api_mtx);
    if (!r)
        return NULL;
    char *out = utf16_to_utf8(r, rl);
    free(r);
    if (out && !out[0]) {
        free(out);
        out = NULL;
    }
    return out;
}

char *tv_session_enum_channel(tv_session *s, uint32_t space, uint32_t ch)
{
    pthread_mutex_lock(&s->api_mtx);
    uint32_t be[2] = {htonl(space), htonl(ch)}, rl = 0;
    uint8_t *r = s->fd >= 0 ? call(s, eEnumChannelName, be, 8, 0, 5000, &rl) : NULL;
    pthread_mutex_unlock(&s->api_mtx);
    if (!r)
        return NULL;
    char *out = utf16_to_utf8(r, rl);
    free(r);
    if (out && !out[0]) {
        free(out);
        out = NULL;
    }
    return out;
}

int tv_session_set_channel(tv_session *s, uint32_t space, uint32_t ch, uint16_t sid, int lock_priority)
{
    pthread_mutex_lock(&s->api_mtx);
    if (s->fd < 0 || s->conn_closed) {
        pthread_mutex_unlock(&s->api_mtx);
        return -1;
    }
    uint8_t body[9];
    uint32_t a = htonl(space), b = htonl(ch);
    memcpy(body, &a, 4);
    memcpy(body + 4, &b, 4);
    body[8] = (uint8_t)lock_priority;
    s->tune_sid = sid;
    s->tune_start = now_ms();
    atomic_store(&s->tuning, true);
    atomic_store(&s->discard_ts, true);
    uint32_t rl = 0;
    uint8_t *r = call(s, eSetChannel2, body, 9, (uint8_t)atomic_load(&s->opts), 15000, &rl);
    atomic_store(&s->tuning, false);
    int res = -1;
    if (r && rl >= 4) {
        uint32_t v;
        memcpy(&v, r, 4);
        res = (int)ntohl(v);
    }
    free(r);
    if (res != 0)
        atomic_store(&s->discard_ts, false);
    pthread_mutex_unlock(&s->api_mtx);
    return res;
}

void tv_session_select_service(tv_session *s, uint16_t sid)
{
    atomic_store(&s->req_sid, sid);
}

void tv_session_set_audio(tv_session *s, int es_index, int dual_mono_mode)
{
    if (es_index >= 0)
        atomic_store(&s->req_audio, es_index);
    tv_decoder_set_dual_mono(s->adec, dual_mono_mode);
}

void tv_session_set_deinterlace(tv_session *s, bool on)
{
    tv_decoder_set_deinterlace(s->vdec, on);
}

void tv_session_set_audio_tap(tv_session *s, bool on)
{
    atomic_store(&s->tap_on, on);
}

uint32_t tv_session_set_output_delay(tv_session *s, int ms)
{
    atomic_store(&s->delay_ms, ms > 0 ? ms : 0);
    return bump_generation(s);
}

void tv_session_set_drift_correction(tv_session *s, uint32_t gen, int ppm)
{
    tv_timeline_set_ppm(s->timeline, gen, ppm);
}

void tv_session_set_options(tv_session *s, int opts)
{
    atomic_store(&s->opts, opts);
}
