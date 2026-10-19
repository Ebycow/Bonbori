// SPDX-License-Identifier: GPL-2.0-or-later
#include "internal.h"
#include "TVCore.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

void sb_init(sbuf *b)
{
    b->cap = 256;
    b->len = 0;
    b->buf = malloc(b->cap);
    b->buf[0] = 0;
}

void sb_free(sbuf *b)
{
    free(b->buf);
    b->buf = NULL;
    b->len = b->cap = 0;
}

static void sb_reserve(sbuf *b, size_t extra)
{
    if (b->len + extra + 1 <= b->cap)
        return;
    while (b->len + extra + 1 > b->cap)
        b->cap *= 2;
    b->buf = realloc(b->buf, b->cap);
}

void sb_putc(sbuf *b, char c)
{
    sb_reserve(b, 1);
    b->buf[b->len++] = c;
    b->buf[b->len] = 0;
}

void sb_puts(sbuf *b, const char *s)
{
    size_t n = strlen(s);
    sb_reserve(b, n);
    memcpy(b->buf + b->len, s, n + 1);
    b->len += n;
}

void sb_printf(sbuf *b, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    char tmp[512];
    int n = vsnprintf(tmp, sizeof(tmp), fmt, ap);
    va_end(ap);
    if (n < 0)
        return;
    if ((size_t)n < sizeof(tmp)) {
        sb_puts(b, tmp);
        return;
    }
    sb_reserve(b, (size_t)n);
    va_start(ap, fmt);
    vsnprintf(b->buf + b->len, (size_t)n + 1, fmt, ap);
    va_end(ap);
    b->len += (size_t)n;
}

void sb_json_str(sbuf *b, const char *s)
{
    sb_putc(b, '"');
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        switch (*p) {
        case '"': sb_puts(b, "\\\""); break;
        case '\\': sb_puts(b, "\\\\"); break;
        case '\n': sb_puts(b, "\\n"); break;
        case '\r': sb_puts(b, "\\r"); break;
        case '\t': sb_puts(b, "\\t"); break;
        default:
            if (*p < 0x20)
                sb_printf(b, "\\u%04x", *p);
            else
                sb_putc(b, (char)*p);
        }
    }
    sb_putc(b, '"');
}

static uint32_t crc_table[256];
static pthread_once_t crc_once = PTHREAD_ONCE_INIT;

static void crc_init(void)
{
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i << 24;
        for (int j = 0; j < 8; j++)
            c = (c & 0x80000000) ? (c << 1) ^ 0x04C11DB7 : (c << 1);
        crc_table[i] = c;
    }
}

uint32_t crc32_mpeg(const uint8_t *p, size_t n)
{
    pthread_once(&crc_once, crc_init);
    uint32_t c = 0xFFFFFFFF;
    while (n--)
        c = (c << 8) ^ crc_table[((c >> 24) ^ *p++) & 0xFF];
    return c;
}

int64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

void tv_free(void *p)
{
    free(p);
}

// ----------------------------------------------------------------- presentation timeline
struct tv_timeline {
    pthread_mutex_t mtx;
    uint32_t gen;
    int64_t offset;
    int ppm;
};

tv_timeline *tv_timeline_create(void)
{
    tv_timeline *t = calloc(1, sizeof(*t));
    pthread_mutex_init(&t->mtx, NULL);
    return t;
}

void tv_timeline_destroy(tv_timeline *t)
{
    if (!t)
        return;
    pthread_mutex_destroy(&t->mtx);
    free(t);
}

// Caller holds the lock. False for an older generation; a newer one starts from zero.
static bool timeline_enter(tv_timeline *t, uint32_t gen)
{
    if (gen == t->gen)
        return true;
    if ((int32_t)(gen - t->gen) < 0)
        return false;
    t->gen = gen;
    t->offset = 0;
    t->ppm = 0;
    return true;
}

void tv_timeline_get(tv_timeline *t, uint32_t gen, int64_t *offset90k, int *ppm)
{
    pthread_mutex_lock(&t->mtx);
    bool cur = timeline_enter(t, gen);
    *offset90k = cur ? t->offset : 0;
    *ppm = cur ? t->ppm : 0;
    pthread_mutex_unlock(&t->mtx);
}

void tv_timeline_set_offset(tv_timeline *t, uint32_t gen, int64_t offset90k)
{
    pthread_mutex_lock(&t->mtx);
    if (timeline_enter(t, gen))
        t->offset = offset90k;
    pthread_mutex_unlock(&t->mtx);
}

void tv_timeline_set_ppm(tv_timeline *t, uint32_t gen, int ppm)
{
    pthread_mutex_lock(&t->mtx);
    if (timeline_enter(t, gen))
        t->ppm = ppm;
    pthread_mutex_unlock(&t->mtx);
}
