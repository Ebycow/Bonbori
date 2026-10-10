// SPDX-License-Identifier: GPL-2.0-or-later
// ARIB STD-B24 8-unit character code -> UTF-8.
// Covers what appears in SI (SDT/NIT/EIT): Kanji (JIS X 0208 via iconv), alphanumeric,
// hiragana, katakana, JIS X 0201 katakana and the common additional symbols.
#include "internal.h"

#include <iconv.h>
#include <string.h>

enum {
    CS_KANJI = 0x42,
    CS_JIS1 = 0x39,  // JIS compatible Kanji plane 1
    CS_JIS2 = 0x3A,  // JIS compatible Kanji plane 2
    CS_SYMBOL = 0x3B,
    CS_ALNUM = 0x4A,
    CS_HIRA = 0x30,
    CS_KATA = 0x31,
    CS_MOSAIC_A = 0x32,
    CS_MOSAIC_B = 0x33,
    CS_MOSAIC_C = 0x34,
    CS_MOSAIC_D = 0x35,
    CS_P_ALNUM = 0x36,
    CS_P_HIRA = 0x37,
    CS_P_KATA = 0x38,
    CS_JISX0201 = 0x49,
    CS_DRCS = 0x100,  // any DRCS set
};

typedef struct {
    int set;
    int bytes;
} gset;

static uint16_t jis_table[94 * 94];
static pthread_once_t jis_once = PTHREAD_ONCE_INIT;

static void jis_init(void)
{
    iconv_t cd = iconv_open("UTF-16LE", "EUC-JP");
    if (cd == (iconv_t)-1)
        return;
    for (int r = 0; r < 94; r++) {
        for (int c = 0; c < 94; c++) {
            char in[2] = {(char)(0xA1 + r), (char)(0xA1 + c)};
            char out[8];
            char *ip = in, *op = out;
            size_t il = 2, ol = sizeof(out);
            iconv(cd, NULL, NULL, NULL, NULL);
            if (iconv(cd, &ip, &il, &op, &ol) != (size_t)-1 && ol == sizeof(out) - 2)
                jis_table[r * 94 + c] = (uint16_t)((uint8_t)out[0] | ((uint8_t)out[1] << 8));
        }
    }
    iconv_close(cd);
}

// Row 90 (0x7A) additional symbols, columns 0x50..0x74. Text forms follow LibISDB's ARIBString.cpp
// (Copyright (c) DBCTRADO, GPL-2.0-or-later).
static const char *const sym_row90[] = {
    "[HV]", "[SD]", "[P]", "[W]", "[MV]", "[手]", "[字]", "[双]", "[デ]", "[S]", "[二]", "[多]",
    "[解]", "[SS]", "[B]", "[N]", "■", "●", "[天]", "[交]", "[映]", "[無]", "[料]", "[年齢制限]",
    "[前]", "[後]", "[再]", "[新]", "[初]", "[終]", "[生]", "[販]", "[声]", "[吹]", "[PPV]",
    "(秘)", "ほか",
};

typedef struct {
    char *dst;
    size_t cap, len;
} out_t;

static void put_utf8(out_t *o, uint32_t cp)
{
    char b[4];
    int n;
    if (cp < 0x80) {
        b[0] = (char)cp;
        n = 1;
    } else if (cp < 0x800) {
        b[0] = (char)(0xC0 | (cp >> 6));
        b[1] = (char)(0x80 | (cp & 0x3F));
        n = 2;
    } else if (cp < 0x10000) {
        b[0] = (char)(0xE0 | (cp >> 12));
        b[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        b[2] = (char)(0x80 | (cp & 0x3F));
        n = 3;
    } else {
        b[0] = (char)(0xF0 | (cp >> 18));
        b[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
        b[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
        b[3] = (char)(0x80 | (cp & 0x3F));
        n = 4;
    }
    if (o->len + (size_t)n + 1 > o->cap)
        return;
    memcpy(o->dst + o->len, b, (size_t)n);
    o->len += (size_t)n;
}

static void put_str(out_t *o, const char *s)
{
    size_t n = strlen(s);
    if (o->len + n + 1 > o->cap)
        return;
    memcpy(o->dst + o->len, s, n);
    o->len += n;
}

// Full-width ASCII variants are folded to ASCII for display on macOS.
static void put_cp(out_t *o, uint32_t cp)
{
    if (cp >= 0xFF01 && cp <= 0xFF5E)
        cp = cp - 0xFF01 + 0x21;
    else if (cp == 0x3000)
        cp = 0x20;
    put_utf8(o, cp);
}

static void put_kanji(out_t *o, int c1, int c2)
{
    c1 &= 0x7F;
    c2 &= 0x7F;
    if (c1 < 0x21 || c1 > 0x7E || c2 < 0x21 || c2 > 0x7E)
        return;
    if (c1 >= 0x7A) {
        if (c1 == 0x7A && c2 >= 0x50 && c2 - 0x50 < (int)(sizeof(sym_row90) / sizeof(sym_row90[0])))
            put_str(o, sym_row90[c2 - 0x50]);
        else
            put_cp(o, 0x3013);  // 〓
        return;
    }
    uint16_t u = jis_table[(c1 - 0x21) * 94 + (c2 - 0x21)];
    put_cp(o, u ? u : 0x3013);
}

static const uint16_t kana_tail[] = {0x30FD, 0x30FE, 0x30FC, 0x3002, 0x300C, 0x300D, 0x3001, 0x30FB};

static void put_1byte(out_t *o, int set, int c)
{
    c &= 0x7F;
    switch (set) {
    case CS_ALNUM:
    case CS_P_ALNUM:
        if (c == 0x5C)
            put_utf8(o, 0x00A5);
        else if (c == 0x7E)
            put_utf8(o, 0x203E);
        else
            put_utf8(o, (uint32_t)c);
        break;
    case CS_HIRA:
    case CS_P_HIRA:
        if (c <= 0x73)
            put_utf8(o, 0x3041 + (uint32_t)(c - 0x21));
        else if (c >= 0x77) {
            uint16_t u = kana_tail[c - 0x77];
            if (c == 0x77)
                u = 0x309D;
            else if (c == 0x78)
                u = 0x309E;
            put_utf8(o, u);
        }
        break;
    case CS_KATA:
    case CS_P_KATA:
        if (c <= 0x76)
            put_utf8(o, 0x30A1 + (uint32_t)(c - 0x21));
        else
            put_utf8(o, kana_tail[c - 0x77]);
        break;
    case CS_JISX0201:
        if (c <= 0x5F)
            put_utf8(o, 0xFF61 + (uint32_t)(c - 0x21));
        break;
    default:
        break;  // mosaic / DRCS: no glyph
    }
}

static bool is_2byte_set(int set)
{
    return set == CS_KANJI || set == CS_JIS1 || set == CS_JIS2 || set == CS_SYMBOL;
}

size_t arib_to_utf8(const uint8_t *src, size_t len, char *dst, size_t cap)
{
    pthread_once(&jis_once, jis_init);
    out_t o = {dst, cap, 0};
    if (cap == 0)
        return 0;

    gset g[4] = {{CS_KANJI, 2}, {CS_ALNUM, 1}, {CS_HIRA, 1}, {CS_KATA, 1}};
    int gl = 0, gr = 2, ss = -1;

    size_t i = 0;
    while (i < len) {
        uint8_t b = src[i];
        if (b < 0x20) {
            i++;
            switch (b) {
            case 0x0D: put_utf8(&o, '\n'); break;
            case 0x0E: gl = 1; break;
            case 0x0F: gl = 0; break;
            case 0x19: ss = 2; break;
            case 0x1D: ss = 3; break;
            case 0x16: i += 1; break;  // PAPF
            case 0x1C: i += 2; break;  // APS
            case 0x1B: {
                if (i >= len)
                    break;
                uint8_t e = src[i++];
                if (e == 0x6E) gl = 2;
                else if (e == 0x6F) gl = 3;
                else if (e == 0x7E) gr = 1;
                else if (e == 0x7D) gr = 2;
                else if (e == 0x7C) gr = 3;
                else if (e >= 0x28 && e <= 0x2B) {
                    int n = e - 0x28;
                    if (i < len && src[i] == 0x20) {
                        i++;
                        if (i < len) i++;
                        g[n].set = CS_DRCS;
                        g[n].bytes = 1;
                    } else if (i < len) {
                        g[n].set = src[i++];
                        g[n].bytes = 1;
                    }
                } else if (e == 0x24) {
                    if (i >= len)
                        break;
                    uint8_t f = src[i];
                    if (f >= 0x28 && f <= 0x2B) {
                        int n = f - 0x28;
                        i++;
                        if (i < len && src[i] == 0x20) {
                            i++;
                            if (i < len) i++;
                            g[n].set = CS_DRCS;
                            g[n].bytes = 2;
                        } else if (i < len) {
                            g[n].set = src[i++];
                            g[n].bytes = 2;
                        }
                    } else {
                        g[0].set = f;
                        g[0].bytes = 2;
                        i++;
                    }
                }
                break;
            }
            default: break;
            }
            continue;
        }
        if (b == 0x20) {
            put_utf8(&o, ' ');
            i++;
            continue;
        }
        if (b == 0x7F || b == 0xA0 || b == 0xFF) {
            i++;
            continue;
        }
        if (b >= 0x80 && b <= 0x9F) {
            i++;
            switch (b) {
            case 0x8B: case 0x91: case 0x93: case 0x94: case 0x97: case 0x98:
                i += 1;
                break;
            case 0x90:  // COL
                i += (i < len && src[i] == 0x20) ? 2 : 1;
                break;
            case 0x9D:  // TIME
                i += 2;
                break;
            case 0x95:  // MACRO ... 0x95 0x4F
                while (i + 1 < len && !(src[i] == 0x95 && src[i + 1] == 0x4F))
                    i++;
                i += 2;
                break;
            case 0x9B:  // CSI: parameters end with a final byte 0x40-0x6F
                while (i < len && !(src[i] >= 0x40 && src[i] <= 0x6F))
                    i++;
                i++;
                break;
            default:
                break;
            }
            continue;
        }
        // graphic character
        gset cur;
        if (ss >= 0) {
            cur = g[ss];
            ss = -1;
        } else {
            cur = (b < 0x80) ? g[gl] : g[gr];
        }
        if (cur.bytes == 2 || is_2byte_set(cur.set)) {
            if (i + 1 >= len)
                break;
            if (cur.set == CS_DRCS)
                put_cp(&o, 0x3013);
            else
                put_kanji(&o, src[i], src[i + 1]);
            i += 2;
        } else {
            put_1byte(&o, cur.set, b);
            i++;
        }
    }
    o.dst[o.len] = 0;
    return o.len;
}
