// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef TVCORE_INTERNAL_H
#define TVCORE_INTERNAL_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <pthread.h>
#include <stdatomic.h>

#define TV_NOPTS INT64_MIN

// ---------------------------------------------------------------- util
typedef struct {
    char *buf;
    size_t len, cap;
} sbuf;

void sb_init(sbuf *b);
void sb_free(sbuf *b);
void sb_putc(sbuf *b, char c);
void sb_puts(sbuf *b, const char *s);
void sb_printf(sbuf *b, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
void sb_json_str(sbuf *b, const char *s);  // writes a quoted, escaped JSON string

uint32_t crc32_mpeg(const uint8_t *p, size_t n);
int64_t now_ms(void);

// ---------------------------------------------------------------- ARIB STD-B24
// Decodes an ARIB 8-unit string into UTF-8 (NUL terminated). Returns length.
size_t arib_to_utf8(const uint8_t *src, size_t len, char *dst, size_t cap);

// ---------------------------------------------------------------- demux
enum { PES_VIDEO = 0, PES_AUDIO = 1 };

typedef struct {
    void *ctx;
    void (*on_pes)(void *ctx, int kind, int stream_type, const uint8_t *data, size_t len,
                   int64_t pts, int64_t dts);
    void (*on_pcr)(void *ctx, int64_t pcr90k);
    void (*on_event)(void *ctx, int type, const char *json);
    // Called when the selected service changes (stream reset needed).
    void (*on_service_switch)(void *ctx, int sid);
} tv_demux_cb;

typedef struct tv_demux tv_demux;

tv_demux *tv_demux_create(tv_demux_cb cb);
void tv_demux_destroy(tv_demux *d);
// Forget everything about the current TS and select `sid` (0 = auto) on the next PAT.
void tv_demux_reset(tv_demux *d, int sid);
void tv_demux_select_service(tv_demux *d, int sid);
void tv_demux_select_audio(tv_demux *d, int index);
void tv_demux_feed(tv_demux *d, const uint8_t *data, size_t len);

typedef struct {
    uint64_t packets, scrambled, drops, errors;
} tv_demux_stats;
void tv_demux_get_stats(tv_demux *d, tv_demux_stats *st);

// ---------------------------------------------------------------- decoders
typedef struct tv_decoder tv_decoder;
typedef struct {
    void *ctx;
    void (*on_video)(void *ctx, void *sample_buffer, uint32_t gen);
    void (*on_audio)(void *ctx, void *sample_buffer, uint32_t gen);
    void (*on_info)(void *ctx, int kind, const char *json);
} tv_decoder_cb;

tv_decoder *tv_decoder_create(int kind, tv_decoder_cb cb);
void tv_decoder_destroy(tv_decoder *d);
void tv_decoder_push(tv_decoder *d, int stream_type, const uint8_t *data, size_t len,
                     int64_t pts, int64_t dts, uint32_t gen);
// Drop everything queued and reset codec state before processing packets of `gen`.
void tv_decoder_flush(tv_decoder *d, uint32_t gen);
void tv_decoder_set_deinterlace(tv_decoder *d, bool on);
void tv_decoder_set_dual_mono(tv_decoder *d, int mode);
int tv_decoder_queue_len(tv_decoder *d);

#endif
