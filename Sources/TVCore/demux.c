// SPDX-License-Identifier: GPL-2.0-or-later
// MPEG-2 TS demuxer specialised for ISDB (ARIB) broadcasts.
#include "internal.h"
#include "TVCore.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAX_PROGRAMS 64
#define MAX_SERVICES 64
#define MAX_ES 32
#define TS_SIZE 188
#define RING_PACKETS 12288  // ~2.3MB: covers the PAT/PMT wait after a tune
#define EIT_SEEN_SLOTS 65536  // EIT sections already passed on in this tune (BS carries ~30k)

typedef struct {
    uint8_t *buf;
    int len;
    bool active;
} section_buf;

typedef struct {
    uint8_t *buf;
    size_t len, cap;
    size_t expected;  // 0 = unbounded (until next PUSI)
    bool active;
    bool corrupt;
    int pid;
    int stream_type;
} pes_asm;

typedef struct {
    int pid;
    int stream_type;
    int component_tag;
} es_info;

typedef struct {
    int sid;
    int type;
    char name[128];
} service_info;

typedef struct {
    int event_id;
    int64_t start;  // unix time (JST wall clock interpreted as UTC+9)
    int duration;   // seconds, -1 unknown
    char title[256];
    char text[512];
    bool valid;
} event_info;

struct tv_demux {
    tv_demux_cb cb;

    uint8_t residue[TS_SIZE];
    int residue_len;

    section_buf *sections[8192];
    int8_t cc[8192];

    // PAT
    int tsid;
    int pat_version;
    int nprog;
    struct { int number, pmt_pid; } prog[MAX_PROGRAMS];

    // selection
    int target_sid;  // requested (0 = auto)
    int cur_sid;
    int pmt_pid;
    int pmt_version;
    int pcr_pid;
    int nes;
    es_info es[MAX_ES];
    int audio_index;
    pes_asm video, audio;

    // SDT / NIT
    int onid;
    int sdt_version;
    uint32_t sdt_sections_seen;
    int sdt_last_section;
    int nservices;
    service_info services[MAX_SERVICES];
    bool sdt_complete;
    int nid;
    char ts_name[128];
    char network_name[128];
    int remote_key;

    // EIT p/f of current service
    int eit_version[2];
    event_info events[2];

    // EIT sections (any service) already emitted as TV_EV_EIT: key -> version
    uint64_t *eit_keys;
    uint8_t *eit_vers;
    int eit_count;

    // time
    int64_t ts_ref;  // last unwrapped PCR (reference for unwrapping)
    bool has_ref;
    int64_t last_tot;

    // recent packets, replayed for the selected ES once the PMT is known
    uint8_t *ring;
    int ring_head, ring_count;

    tv_demux_stats stats;
};

static void reset_pes(pes_asm *p)
{
    p->len = 0;
    p->active = false;
    p->corrupt = false;
    p->expected = 0;
}

tv_demux *tv_demux_create(tv_demux_cb cb)
{
    tv_demux *d = calloc(1, sizeof(*d));
    d->cb = cb;
    d->video.pid = d->audio.pid = -1;
    d->ring = malloc((size_t)RING_PACKETS * TS_SIZE);
    d->eit_keys = malloc(EIT_SEEN_SLOTS * sizeof(uint64_t));
    d->eit_vers = malloc(EIT_SEEN_SLOTS);
    tv_demux_reset(d, 0);
    return d;
}

void tv_demux_destroy(tv_demux *d)
{
    if (!d)
        return;
    for (int i = 0; i < 8192; i++) {
        if (d->sections[i]) {
            free(d->sections[i]->buf);
            free(d->sections[i]);
        }
    }
    free(d->video.buf);
    free(d->audio.buf);
    free(d->ring);
    free(d->eit_keys);
    free(d->eit_vers);
    free(d);
}

static void clear_selection(tv_demux *d)
{
    d->pmt_pid = -1;
    d->pmt_version = -1;
    d->pcr_pid = -1;
    d->nes = 0;
    d->video.pid = d->audio.pid = -1;
    reset_pes(&d->video);
    reset_pes(&d->audio);
    d->eit_version[0] = d->eit_version[1] = -1;
    memset(d->events, 0, sizeof(d->events));
}

void tv_demux_reset(tv_demux *d, int sid)
{
    d->residue_len = 0;
    d->ring_head = d->ring_count = 0;
    memset(d->cc, -1, sizeof(d->cc));
    for (int i = 0; i < 8192; i++)
        if (d->sections[i])
            d->sections[i]->active = false;
    d->tsid = -1;
    d->pat_version = -1;
    d->nprog = 0;
    d->target_sid = sid;
    d->cur_sid = -1;
    clear_selection(d);
    d->onid = -1;
    d->sdt_version = -1;
    d->sdt_sections_seen = 0;
    d->sdt_last_section = 0;
    d->nservices = 0;
    d->sdt_complete = false;
    d->nid = -1;
    d->ts_name[0] = 0;
    d->network_name[0] = 0;
    d->remote_key = 0;
    d->has_ref = false;
    d->last_tot = 0;
    memset(d->eit_keys, 0, EIT_SEEN_SLOTS * sizeof(uint64_t));
    d->eit_count = 0;
    memset(&d->stats, 0, sizeof(d->stats));
}

void tv_demux_get_stats(tv_demux *d, tv_demux_stats *st)
{
    *st = d->stats;
}

// ----------------------------------------------------------------- timestamps
static int64_t unwrap(tv_demux *d, int64_t ts)
{
    const int64_t wrap = 1LL << 33;
    if (!d->has_ref) {
        d->ts_ref = ts;
        d->has_ref = true;
        return ts;
    }
    int64_t v = (d->ts_ref & ~(wrap - 1)) | ts;
    if (v - d->ts_ref > wrap / 2)
        v -= wrap;
    else if (d->ts_ref - v > wrap / 2)
        v += wrap;
    return v;
}

static int64_t read_ts(const uint8_t *p)
{
    return ((int64_t)(p[0] & 0x0E) << 29) | ((int64_t)p[1] << 22) | ((int64_t)(p[2] & 0xFE) << 14) |
           ((int64_t)p[3] << 7) | ((int64_t)p[4] >> 1);
}

// MJD + BCD hhmmss -> unix seconds (treating JST as is; caller subtracts 9h if needed)
static int bcd(uint8_t v)
{
    return (v >> 4) * 10 + (v & 0x0F);
}

static int64_t mjd_bcd_to_unix(const uint8_t *p)
{
    int mjd = (p[0] << 8) | p[1];
    if (mjd == 0xFFFF)
        return -1;
    int64_t days = (int64_t)mjd - 40587;  // 1970-01-01
    int64_t secs = days * 86400 + bcd(p[2]) * 3600 + bcd(p[3]) * 60 + bcd(p[4]);
    return secs - 9 * 3600;  // JST -> UTC
}

static int bcd_duration(const uint8_t *p)
{
    if (p[0] == 0xFF && p[1] == 0xFF && p[2] == 0xFF)
        return -1;
    return bcd(p[0]) * 3600 + bcd(p[1]) * 60 + bcd(p[2]);
}

// ----------------------------------------------------------------- events
static void emit(tv_demux *d, int type, sbuf *b)
{
    if (d->cb.on_event)
        d->cb.on_event(d->cb.ctx, type, b->buf);
    sb_free(b);
}

static void emit_services(tv_demux *d)
{
    sbuf b;
    sb_init(&b);
    sb_printf(&b, "{\"onid\":%d,\"tsid\":%d,\"nid\":%d,\"remote_key\":%d,\"complete\":%s,\"tsname\":",
              d->onid, d->tsid, d->nid, d->remote_key, d->sdt_complete ? "true" : "false");
    sb_json_str(&b, d->ts_name);
    sb_puts(&b, ",\"network\":");
    sb_json_str(&b, d->network_name);
    sb_puts(&b, ",\"services\":[");
    for (int i = 0; i < d->nservices; i++) {
        if (i)
            sb_putc(&b, ',');
        sb_printf(&b, "{\"sid\":%d,\"type\":%d,\"name\":", d->services[i].sid, d->services[i].type);
        sb_json_str(&b, d->services[i].name);
        sb_putc(&b, '}');
    }
    sb_puts(&b, "],\"pat\":[");
    for (int i = 0; i < d->nprog; i++)
        sb_printf(&b, "%s%d", i ? "," : "", d->prog[i].number);
    sb_puts(&b, "]}");
    emit(d, TV_EV_SERVICES, &b);
}

static void emit_event_json(sbuf *b, const event_info *e)
{
    if (!e->valid) {
        sb_puts(b, "null");
        return;
    }
    sb_printf(b, "{\"event_id\":%d,\"start\":%lld,\"duration\":%d,\"title\":", e->event_id,
              (long long)e->start, e->duration);
    sb_json_str(b, e->title);
    sb_puts(b, ",\"text\":");
    sb_json_str(b, e->text);
    sb_putc(b, '}');
}

static void emit_program(tv_demux *d)
{
    sbuf b;
    sb_init(&b);
    sb_printf(&b, "{\"sid\":%d,\"present\":", d->cur_sid);
    emit_event_json(&b, &d->events[0]);
    sb_puts(&b, ",\"following\":");
    emit_event_json(&b, &d->events[1]);
    sb_putc(&b, '}');
    emit(d, TV_EV_PROGRAM, &b);
}

static const char *stream_type_name(int st)
{
    switch (st) {
    case 0x01: return "MPEG-1";
    case 0x02: return "MPEG-2";
    case 0x1B: return "H.264";
    case 0x24: return "HEVC";
    case 0x0F: return "AAC";
    case 0x11: return "AAC-LATM";
    case 0x03: case 0x04: return "MPEG Audio";
    default: return "?";
    }
}

static void emit_stream(tv_demux *d)
{
    sbuf b;
    sb_init(&b);
    int vst = -1, ast = -1, naudio = 0;
    for (int i = 0; i < d->nes; i++) {
        if (d->es[i].pid == d->video.pid)
            vst = d->es[i].stream_type;
        if (d->es[i].pid == d->audio.pid)
            ast = d->es[i].stream_type;
        int st = d->es[i].stream_type;
        if (st == 0x0F || st == 0x11 || st == 0x03 || st == 0x04)
            naudio++;
    }
    sb_printf(&b, "{\"sid\":%d,\"video_pid\":%d,\"audio_pid\":%d,\"pcr_pid\":%d,\"video\":", d->cur_sid,
              d->video.pid, d->audio.pid, d->pcr_pid);
    sb_json_str(&b, vst >= 0 ? stream_type_name(vst) : "");
    sb_puts(&b, ",\"audio\":");
    sb_json_str(&b, ast >= 0 ? stream_type_name(ast) : "");
    sb_printf(&b, ",\"audio_count\":%d,\"audio_index\":%d}", naudio, d->audio_index);
    emit(d, TV_EV_STREAM, &b);
}

// ----------------------------------------------------------------- selection
static bool is_video_type(int st)
{
    return st == 0x01 || st == 0x02 || st == 0x1B || st == 0x24;
}

static bool is_audio_type(int st)
{
    return st == 0x0F || st == 0x11 || st == 0x03 || st == 0x04;
}

static bool is_tv_service_type(int t)
{
    return t == 0x01 || t == 0xA5 || t == 0xAD;
}

static int service_type_of(tv_demux *d, int sid)
{
    for (int i = 0; i < d->nservices; i++)
        if (d->services[i].sid == sid)
            return d->services[i].type;
    return -1;
}

static void choose_program(tv_demux *d)
{
    int sid = -1;
    if (d->target_sid > 0) {
        for (int i = 0; i < d->nprog; i++)
            if (d->prog[i].number == d->target_sid)
                sid = d->target_sid;
    }
    if (sid < 0 && d->nservices > 0) {
        // first TV service in SDT order that is in the PAT
        for (int j = 0; j < d->nservices && sid < 0; j++) {
            if (!is_tv_service_type(d->services[j].type))
                continue;
            for (int i = 0; i < d->nprog; i++)
                if (d->prog[i].number == d->services[j].sid) {
                    sid = d->services[j].sid;
                    break;
                }
        }
    }
    if (sid < 0) {
        for (int i = 0; i < d->nprog; i++) {
            if (d->prog[i].number != 0) {
                sid = d->prog[i].number;
                break;
            }
        }
    }
    if (sid < 0 || sid == d->cur_sid)
        return;

    bool first = d->cur_sid < 0;
    d->cur_sid = sid;
    clear_selection(d);
    for (int i = 0; i < d->nprog; i++)
        if (d->prog[i].number == sid)
            d->pmt_pid = d->prog[i].pmt_pid;
    if (!first && d->cb.on_service_switch)
        d->cb.on_service_switch(d->cb.ctx, sid);
}

void tv_demux_select_service(tv_demux *d, int sid)
{
    d->target_sid = sid;
    if (d->nprog > 0)
        choose_program(d);
}

static void feed_pes(tv_demux *d, pes_asm *pa, int kind, bool pusi, const uint8_t *p, int n);

// Feed the buffered packets of the newly selected video/audio PIDs, so that an I-frame
// that went by while we were still waiting for the PAT/PMT is not lost.
static void replay_ring(tv_demux *d)
{
    int start = (d->ring_head - d->ring_count + RING_PACKETS) % RING_PACKETS;
    int last_cc[2] = {-1, -1};
    for (int i = 0; i < d->ring_count; i++) {
        const uint8_t *p = d->ring + (size_t)((start + i) % RING_PACKETS) * TS_SIZE;
        int pid = ((p[1] & 0x1F) << 8) | p[2];
        int k = pid == d->video.pid ? 0 : pid == d->audio.pid ? 1 : -1;
        if (k < 0 || (p[1] & 0x80) || (p[3] >> 6))
            continue;
        int afc = (p[3] >> 4) & 3, cc = p[3] & 0x0F;
        if (!(afc & 1) || cc == last_cc[k])
            continue;
        last_cc[k] = cc;
        int off = 4;
        if (afc & 2)
            off += 1 + p[4];
        if (off >= TS_SIZE)
            continue;
        if (k == 0)
            feed_pes(d, &d->video, PES_VIDEO, (p[1] & 0x40) != 0, p + off, TS_SIZE - off);
        else
            feed_pes(d, &d->audio, PES_AUDIO, (p[1] & 0x40) != 0, p + off, TS_SIZE - off);
    }
}

static void apply_es_selection(tv_demux *d)
{
    int vpid = -1, vst = -1, apid = -1, ast = -1, ai = 0;
    for (int i = 0; i < d->nes; i++) {
        es_info *e = &d->es[i];
        if (vpid < 0 && is_video_type(e->stream_type)) {
            vpid = e->pid;
            vst = e->stream_type;
        }
        if (is_audio_type(e->stream_type)) {
            if (ai == d->audio_index || apid < 0) {
                apid = e->pid;
                ast = e->stream_type;
            }
            ai++;
        }
    }
    bool changed = false;
    if (vpid != d->video.pid || vst != d->video.stream_type) {
        reset_pes(&d->video);
        d->video.pid = vpid;
        d->video.stream_type = vst;
        changed = true;
    }
    if (apid != d->audio.pid || ast != d->audio.stream_type) {
        reset_pes(&d->audio);
        d->audio.pid = apid;
        d->audio.stream_type = ast;
        changed = true;
    }
    if (changed) {
        emit_stream(d);
        replay_ring(d);
    }
}

void tv_demux_select_audio(tv_demux *d, int index)
{
    d->audio_index = index < 0 ? 0 : index;
    if (d->nes > 0)
        apply_es_selection(d);
}

// ----------------------------------------------------------------- tables
static void parse_pat(tv_demux *d, const uint8_t *s, int len)
{
    int tsid = (s[3] << 8) | s[4];
    int version = (s[5] >> 1) & 0x1F;
    if (!(s[5] & 1))
        return;
    if (version == d->pat_version && tsid == d->tsid)
        return;
    d->pat_version = version;
    d->tsid = tsid;
    d->nprog = 0;
    for (int i = 8; i + 4 <= len - 4 && d->nprog < MAX_PROGRAMS; i += 4) {
        int num = (s[i] << 8) | s[i + 1];
        int pid = ((s[i + 2] & 0x1F) << 8) | s[i + 3];
        if (num == 0)
            continue;  // NIT pid
        d->prog[d->nprog].number = num;
        d->prog[d->nprog].pmt_pid = pid;
        d->nprog++;
    }
    // re-resolve PMT pid of the current selection
    int prev = d->cur_sid;
    bool found = false;
    for (int i = 0; i < d->nprog; i++)
        if (d->prog[i].number == prev) {
            found = true;
            if (d->pmt_pid != d->prog[i].pmt_pid) {
                d->pmt_pid = d->prog[i].pmt_pid;
                d->pmt_version = -1;
            }
        }
    if (!found)
        d->cur_sid = -1;
    choose_program(d);
}

static void parse_pmt(tv_demux *d, const uint8_t *s, int len)
{
    int prog = (s[3] << 8) | s[4];
    int version = (s[5] >> 1) & 0x1F;
    if (prog != d->cur_sid || !(s[5] & 1))
        return;
    if (version == d->pmt_version)
        return;
    d->pmt_version = version;
    d->pcr_pid = ((s[8] & 0x1F) << 8) | s[9];
    int pinfo = ((s[10] & 0x0F) << 8) | s[11];
    int i = 12 + pinfo;
    d->nes = 0;
    while (i + 5 <= len - 4 && d->nes < MAX_ES) {
        int st = s[i];
        int pid = ((s[i + 1] & 0x1F) << 8) | s[i + 2];
        int eslen = ((s[i + 3] & 0x0F) << 8) | s[i + 4];
        int tag = -1;
        for (int j = i + 5; j + 2 <= i + 5 + eslen && j + 2 <= len - 4;) {
            int dt = s[j], dl = s[j + 1];
            if (dt == 0x52 && dl >= 1)
                tag = s[j + 2];
            j += 2 + dl;
        }
        d->es[d->nes].pid = pid;
        d->es[d->nes].stream_type = st;
        d->es[d->nes].component_tag = tag;
        d->nes++;
        i += 5 + eslen;
    }
    apply_es_selection(d);
}

static void parse_sdt(tv_demux *d, const uint8_t *s, int len)
{
    if (s[0] != 0x42)  // actual TS only
        return;
    int tsid = (s[3] << 8) | s[4];
    int version = (s[5] >> 1) & 0x1F;
    int secno = s[6], last = s[7];
    if (!(s[5] & 1) || (d->tsid >= 0 && tsid != d->tsid))
        return;
    if (d->tsid < 0)
        d->tsid = tsid;  // SDT can arrive before the PAT
    if (version != d->sdt_version) {
        d->sdt_version = version;
        d->sdt_sections_seen = 0;
        d->nservices = 0;
        d->sdt_complete = false;
    }
    if (secno < 32 && (d->sdt_sections_seen & (1u << secno)))
        return;
    if (secno < 32)
        d->sdt_sections_seen |= 1u << secno;
    d->sdt_last_section = last;
    d->onid = (s[8] << 8) | s[9];

    int i = 11;
    while (i + 5 <= len - 4) {
        int sid = (s[i] << 8) | s[i + 1];
        int dlen = ((s[i + 3] & 0x0F) << 8) | s[i + 4];
        int type = -1;
        char name[128] = "";
        for (int j = i + 5; j + 2 <= i + 5 + dlen && j + 2 <= len - 4;) {
            int dt = s[j], dl = s[j + 1];
            if (dt == 0x48 && dl >= 3) {
                type = s[j + 2];
                int pl = s[j + 3];
                if (4 + pl < dl + 2) {
                    int nl = s[j + 4 + pl];
                    if (5 + pl + nl <= dl + 2)
                        arib_to_utf8(s + j + 5 + pl, (size_t)nl, name, sizeof(name));
                }
            }
            j += 2 + dl;
        }
        if (d->nservices < MAX_SERVICES) {
            service_info *si = &d->services[d->nservices++];
            si->sid = sid;
            si->type = type;
            snprintf(si->name, sizeof(si->name), "%s", name);
        }
        i += 5 + dlen;
    }
    uint32_t want = (last >= 31) ? 0xFFFFFFFFu : ((1u << (last + 1)) - 1);
    if ((d->sdt_sections_seen & want) == want) {
        d->sdt_complete = true;
        // auto selection: prefer a TV service once the SDT tells us the types
        if (d->target_sid <= 0 && d->cur_sid > 0 && !is_tv_service_type(service_type_of(d, d->cur_sid))) {
            int prev = d->cur_sid;
            d->cur_sid = -1;
            choose_program(d);
            if (d->cur_sid < 0)
                d->cur_sid = prev;
            else if (d->cur_sid != prev && d->cb.on_service_switch)
                d->cb.on_service_switch(d->cb.ctx, d->cur_sid);
        }
        emit_services(d);
    }
}

static void parse_nit(tv_demux *d, const uint8_t *s, int len)
{
    if (s[0] != 0x40 || !(s[5] & 1))
        return;
    int nid = (s[3] << 8) | s[4];
    bool changed = nid != d->nid;
    d->nid = nid;
    char tmp[128];
    int ndl = ((s[8] & 0x0F) << 8) | s[9];
    int i = 10;
    for (int j = i; j + 2 <= i + ndl && j + 2 <= len - 4;) {
        int dt = s[j], dl = s[j + 1];
        if (dt == 0x40) {
            arib_to_utf8(s + j + 2, (size_t)dl, tmp, sizeof(tmp));
            if (strcmp(tmp, d->network_name) != 0) {
                memcpy(d->network_name, tmp, sizeof(tmp));
                changed = true;
            }
        }
        j += 2 + dl;
    }
    i += ndl;
    if (i + 2 > len - 4)
        return;
    int tsl = ((s[i] & 0x0F) << 8) | s[i + 1];
    i += 2;
    int end = i + tsl;
    while (i + 6 <= end && i + 6 <= len - 4) {
        int tsid = (s[i] << 8) | s[i + 1];
        int tdl = ((s[i + 4] & 0x0F) << 8) | s[i + 5];
        if (tsid == d->tsid) {
            for (int j = i + 6; j + 2 <= i + 6 + tdl && j + 2 <= len - 4;) {
                int dt = s[j], dl = s[j + 1];
                if (dt == 0xCD && dl >= 2) {  // TS information descriptor
                    if (d->remote_key != s[j + 2]) {
                        d->remote_key = s[j + 2];
                        changed = true;
                    }
                    int nl = s[j + 3] >> 2;
                    tmp[0] = 0;
                    if (2 + nl <= dl)
                        arib_to_utf8(s + j + 4, (size_t)nl, tmp, sizeof(tmp));
                    if (strcmp(tmp, d->ts_name) != 0) {
                        memcpy(d->ts_name, tmp, sizeof(tmp));
                        changed = true;
                    }
                }
                j += 2 + dl;
            }
        }
        i += 6 + tdl;
    }
    if (changed && d->sdt_complete)
        emit_services(d);
}

// ----------------------------------------------------------------- EIT (program guide)
// Returns true the first time a section (table/service/section number) is seen with this version.
static bool eit_seen_update(tv_demux *d, uint64_t key, int version)
{
    if (d->eit_count >= EIT_SEEN_SLOTS * 3 / 4) {
        memset(d->eit_keys, 0, EIT_SEEN_SLOTS * sizeof(uint64_t));
        d->eit_count = 0;
    }
    uint32_t i = (uint32_t)((key * 0x9E3779B97F4A7C15ull) >> 48) & (EIT_SEEN_SLOTS - 1);
    while (d->eit_keys[i] != 0 && d->eit_keys[i] != key)
        i = (i + 1) & (EIT_SEEN_SLOTS - 1);
    if (d->eit_keys[i] == key) {
        if (d->eit_vers[i] == version)
            return false;
    } else {
        d->eit_keys[i] = key;
        d->eit_count++;
    }
    d->eit_vers[i] = (uint8_t)version;
    return true;
}

static void json_arib(sbuf *b, const char *key, const uint8_t *p, size_t n)
{
    size_t cap = n * 8 + 16;  // worst case: 2 bytes -> "[年齢制限]"
    char *tmp = malloc(cap);
    arib_to_utf8(p, n, tmp, cap);
    if (tmp[0]) {
        sb_printf(b, ",\"%s\":", key);
        sb_json_str(b, tmp);
    }
    free(tmp);
}

// One event of an EIT section: event_id .. descriptors (`n` bytes).
static void emit_eit_event(sbuf *b, const uint8_t *e, int n)
{
    sb_printf(b, "{\"id\":%d,\"start\":%lld,\"dur\":%d,\"ca\":%d", (e[0] << 8) | e[1],
              (long long)mjd_bcd_to_unix(e + 2), bcd_duration(e + 7), (e[10] >> 4) & 1);

    // Extended event items: an item whose description is empty continues the previous one
    // (text split across descriptors), so the raw bytes are joined before decoding.
    uint8_t raw[4096];
    int raw_len = 0, nitems = 0;
    bool dropping = false;
    struct { int doff, dlen, coff, clen; } items[32];
    uint8_t genre[16];
    int ngenre = 0, video = -1, naudio = 0, audio[8];
    sbuf group;
    sb_init(&group);

    for (int j = 12; j + 2 <= n;) {
        int tag = e[j], dl = e[j + 1];
        const uint8_t *p = e + j + 2;
        if (j + 2 + dl > n)
            break;
        j += 2 + dl;
        switch (tag) {
        case 0x4D:  // short event
            if (dl >= 4 && 4 + p[3] <= dl) {
                int nl = p[3];
                json_arib(b, "title", p + 4, (size_t)nl);
                if (5 + nl <= dl && 5 + nl + p[4 + nl] <= dl)
                    json_arib(b, "text", p + 5 + nl, p[4 + nl]);
            }
            break;
        case 0x4E: {  // extended event
            if (dl < 5)
                break;
            int end = 5 + p[4];
            if (end > dl)
                end = dl;
            for (int k = 5; k + 1 <= end;) {
                int idl = p[k];
                if (k + 1 + idl + 1 > end)
                    break;
                int icl = p[k + 1 + idl];
                if (k + 2 + idl + icl > end)
                    break;
                if (idl > 0 || nitems == 0) {
                    dropping = nitems == 32;
                    if (!dropping) {
                        items[nitems].doff = raw_len;
                        items[nitems].dlen = idl;
                        memcpy(raw + raw_len, p + k + 1, (size_t)idl);
                        raw_len += idl;
                        items[nitems].coff = raw_len;
                        items[nitems].clen = 0;
                        nitems++;
                    }
                }
                if (!dropping) {
                    // the last item ends the buffer, so a continuation is appended in place
                    memcpy(raw + raw_len, p + k + 2 + idl, (size_t)icl);
                    raw_len += icl;
                    items[nitems - 1].clen += icl;
                }
                k += 2 + idl + icl;
            }
            break;
        }
        case 0x54:  // content (genre)
            for (int k = 0; k + 1 < dl && ngenre < 16; k += 2)
                genre[ngenre++] = p[k];
            break;
        case 0x50:  // component (video)
            if (dl >= 2 && video < 0)
                video = p[1];
            break;
        case 0xC4:  // audio component
            if (dl >= 2 && naudio < 8)
                audio[naudio++] = p[1];
            break;
        case 0xD6:  // event group: type 1 = the same event shared with other services
            if (dl >= 1 && (p[0] >> 4) == 1) {
                int cnt = p[0] & 0x0F;
                for (int k = 0; k < cnt && 1 + 4 * k + 4 <= dl; k++)
                    sb_printf(&group, "%s[%d,%d]", group.len ? "," : "", (p[1 + 4 * k] << 8) | p[2 + 4 * k],
                              (p[3 + 4 * k] << 8) | p[4 + 4 * k]);
            }
            break;
        default:
            break;
        }
    }

    if (ngenre > 0) {
        sb_puts(b, ",\"genre\":[");
        for (int k = 0; k < ngenre; k++)
            sb_printf(b, "%s%d", k ? "," : "", genre[k]);
        sb_putc(b, ']');
    }
    if (nitems > 0) {
        sb_puts(b, ",\"ext\":[");
        for (int k = 0; k < nitems; k++) {
            int cap = (items[k].dlen > items[k].clen ? items[k].dlen : items[k].clen) * 8 + 16;
            char *tmp = malloc((size_t)cap);
            arib_to_utf8(raw + items[k].doff, (size_t)items[k].dlen, tmp, (size_t)cap);
            sb_puts(b, k ? ",[" : "[");
            sb_json_str(b, tmp);
            arib_to_utf8(raw + items[k].coff, (size_t)items[k].clen, tmp, (size_t)cap);
            sb_putc(b, ',');
            sb_json_str(b, tmp);
            sb_putc(b, ']');
            free(tmp);
        }
        sb_putc(b, ']');
    }
    if (group.len)
        sb_printf(b, ",\"group\":[%s]", group.buf);
    if (video >= 0)
        sb_printf(b, ",\"video\":%d", video);
    if (naudio > 0) {
        sb_puts(b, ",\"audio\":[");
        for (int k = 0; k < naudio; k++)
            sb_printf(b, "%s%d", k ? "," : "", audio[k]);
        sb_putc(b, ']');
    }
    sb_putc(b, '}');
    sb_free(&group);
}

// Every EIT section (p/f and schedule, actual and other TS) for the program guide.
static void parse_eit_any(tv_demux *d, const uint8_t *s, int len)
{
    if (len < 18 || !d->cb.on_event)
        return;
    int tid = s[0], sid = (s[3] << 8) | s[4], version = (s[5] >> 1) & 0x1F, secno = s[6];
    int tsid = (s[8] << 8) | s[9], onid = (s[10] << 8) | s[11];
    uint64_t key = ((uint64_t)tid << 56) | ((uint64_t)onid << 40) | ((uint64_t)tsid << 24) |
                   ((uint64_t)sid << 8) | (uint64_t)secno;
    if (!eit_seen_update(d, key, version))
        return;
    sbuf b;
    sb_init(&b);
    sb_printf(&b,
              "{\"onid\":%d,\"tsid\":%d,\"sid\":%d,\"tid\":%d,\"ver\":%d,\"sec\":%d,\"seg_last\":%d,"
              "\"last_tid\":%d,\"events\":[",
              onid, tsid, sid, tid, version, secno, s[12], s[13]);
    int nev = 0;
    for (int i = 14; i + 12 <= len - 4;) {
        int end = i + 12 + (((s[i + 10] & 0x0F) << 8) | s[i + 11]);
        if (end > len - 4)
            break;
        if (nev++)
            sb_putc(&b, ',');
        emit_eit_event(&b, s + i, end - i);
        i = end;
    }
    sb_puts(&b, "]}");
    emit(d, TV_EV_EIT, &b);
}

static void parse_eit(tv_demux *d, const uint8_t *s, int len)
{
    if (!(s[5] & 1))
        return;
    parse_eit_any(d, s, len);
    if (s[0] != 0x4E)
        return;
    int sid = (s[3] << 8) | s[4];
    if (sid != d->cur_sid)
        return;
    int version = (s[5] >> 1) & 0x1F;
    int secno = s[6];
    if (secno > 1 || d->eit_version[secno] == version)
        return;
    d->eit_version[secno] = version;
    event_info *e = &d->events[secno];
    memset(e, 0, sizeof(*e));
    int i = 14;
    if (i + 12 <= len - 4) {
        e->valid = true;
        e->event_id = (s[i] << 8) | s[i + 1];
        e->start = mjd_bcd_to_unix(s + i + 2);
        e->duration = bcd_duration(s + i + 7);
        int dll = ((s[i + 10] & 0x0F) << 8) | s[i + 11];
        for (int j = i + 12; j + 2 <= i + 12 + dll && j + 2 <= len - 4;) {
            int dt = s[j], dl = s[j + 1];
            if (dt == 0x4D && dl >= 5) {  // short event descriptor
                int nl = s[j + 5];
                if (6 + nl <= dl + 1) {
                    arib_to_utf8(s + j + 6, (size_t)nl, e->title, sizeof(e->title));
                    int tl = s[j + 6 + nl];
                    if (7 + nl + tl <= dl + 2)
                        arib_to_utf8(s + j + 7 + nl, (size_t)tl, e->text, sizeof(e->text));
                }
            }
            j += 2 + dl;
        }
    }
    emit_program(d);
}

static void parse_tot(tv_demux *d, const uint8_t *s, int len)
{
    if ((s[0] != 0x70 && s[0] != 0x73) || len < 8)
        return;
    int64_t t = mjd_bcd_to_unix(s + 3);
    if (t <= 0 || t == d->last_tot)
        return;
    d->last_tot = t;
    sbuf b;
    sb_init(&b);
    sb_printf(&b, "{\"utc\":%lld}", (long long)t);
    emit(d, TV_EV_TIME, &b);
}

static void handle_section(tv_demux *d, int pid, const uint8_t *s, int len)
{
    int tid = s[0];
    bool has_crc = (s[1] & 0x80) && tid != 0x70;
    if (has_crc && crc32_mpeg(s, (size_t)len) != 0) {
        d->stats.errors++;
        return;
    }
    if (len < 8 && tid != 0x70)
        return;
    if (pid == 0x00 && tid == 0x00)
        parse_pat(d, s, len);
    else if (pid == d->pmt_pid && tid == 0x02)
        parse_pmt(d, s, len);
    else if (pid == 0x11 && tid == 0x42)
        parse_sdt(d, s, len);
    else if (pid == 0x10 && tid == 0x40)
        parse_nit(d, s, len);
    else if (pid == 0x12 && tid >= 0x4E && tid <= 0x6F)
        parse_eit(d, s, len);
    else if (pid == 0x14)
        parse_tot(d, s, len);
}

static void section_process(tv_demux *d, int pid, section_buf *sb)
{
    int off = 0;
    while (sb->len - off >= 3) {
        uint8_t *s = sb->buf + off;
        if (s[0] == 0xFF) {
            off = sb->len;
            sb->active = false;
            break;
        }
        int total = 3 + (((s[1] & 0x0F) << 8) | s[2]);
        if (total > 4096) {
            off = sb->len;
            sb->active = false;
            break;
        }
        if (sb->len - off < total)
            break;
        handle_section(d, pid, s, total);
        off += total;
    }
    if (off > 0) {
        memmove(sb->buf, sb->buf + off, (size_t)(sb->len - off));
        sb->len -= off;
    }
}

static void section_append(section_buf *sb, const uint8_t *p, int n)
{
    if (sb->len + n > 4096 + TS_SIZE) {
        sb->len = 0;
        sb->active = false;
        return;
    }
    memcpy(sb->buf + sb->len, p, (size_t)n);
    sb->len += n;
}

static void feed_section(tv_demux *d, int pid, bool pusi, const uint8_t *p, int n)
{
    section_buf *sb = d->sections[pid];
    if (!sb) {
        sb = calloc(1, sizeof(*sb));
        sb->buf = malloc(4096 + TS_SIZE);
        d->sections[pid] = sb;
    }
    if (pusi) {
        int ptr = p[0];
        if (1 + ptr > n)
            return;
        if (sb->active && ptr > 0) {
            section_append(sb, p + 1, ptr);
            section_process(d, pid, sb);
        }
        sb->len = 0;
        sb->active = true;
        section_append(sb, p + 1 + ptr, n - 1 - ptr);
        section_process(d, pid, sb);
    } else if (sb->active) {
        section_append(sb, p, n);
        section_process(d, pid, sb);
    }
}

// ----------------------------------------------------------------- PES
static void pes_emit(tv_demux *d, pes_asm *pa, int kind)
{
    if (!pa->active || pa->len < 9)
        goto done;
    const uint8_t *b = pa->buf;
    if (b[0] != 0 || b[1] != 0 || b[2] != 1)
        goto done;
    int flags = b[7];
    int hl = b[8];
    if ((size_t)(9 + hl) > pa->len)
        goto done;
    int64_t pts = TV_NOPTS, dts = TV_NOPTS;
    if ((flags & 0x80) && hl >= 5)
        pts = unwrap(d, read_ts(b + 9));
    if ((flags & 0x40) && hl >= 10)
        dts = unwrap(d, read_ts(b + 14));
    size_t plen = pa->len - 9 - (size_t)hl;
    if (pa->expected > 0 && pa->len > pa->expected)
        plen -= pa->len - pa->expected;
    if (plen > 0 && d->cb.on_pes)
        d->cb.on_pes(d->cb.ctx, kind, pa->stream_type, b + 9 + hl, plen, pts, dts);
done:
    reset_pes(pa);
}

static void feed_pes(tv_demux *d, pes_asm *pa, int kind, bool pusi, const uint8_t *p, int n)
{
    if (pusi) {
        if (pa->active && pa->expected == 0)
            pes_emit(d, pa, kind);
        reset_pes(pa);
        pa->active = true;
        if (n >= 6) {
            int plen = (p[4] << 8) | p[5];
            pa->expected = plen ? (size_t)plen + 6 : 0;
        }
    } else if (!pa->active) {
        return;
    }
    if (pa->len + (size_t)n > pa->cap) {
        size_t nc = pa->cap ? pa->cap : 65536;
        while (nc < pa->len + (size_t)n)
            nc *= 2;
        if (nc > 16 * 1024 * 1024) {
            reset_pes(pa);
            return;
        }
        pa->buf = realloc(pa->buf, nc);
        pa->cap = nc;
    }
    memcpy(pa->buf + pa->len, p, (size_t)n);
    pa->len += (size_t)n;
    if (pa->expected > 0 && pa->len >= pa->expected)
        pes_emit(d, pa, kind);
}

// ----------------------------------------------------------------- packets
static void handle_packet(tv_demux *d, const uint8_t *p)
{
    memcpy(d->ring + (size_t)d->ring_head * TS_SIZE, p, TS_SIZE);
    d->ring_head = (d->ring_head + 1) % RING_PACKETS;
    if (d->ring_count < RING_PACKETS)
        d->ring_count++;
    d->stats.packets++;
    if (p[1] & 0x80) {
        d->stats.errors++;
        return;
    }
    bool pusi = p[1] & 0x40;
    int pid = ((p[1] & 0x1F) << 8) | p[2];
    int scr = p[3] >> 6;
    int afc = (p[3] >> 4) & 3;
    int cc = p[3] & 0x0F;
    if (pid == 0x1FFF)
        return;

    int off = 4;
    if (afc & 2) {
        int al = p[4];
        if (al > 183)
            return;
        if (al >= 7 && pid == d->pcr_pid && (p[5] & 0x10)) {
            int64_t pcr = ((int64_t)p[6] << 25) | ((int64_t)p[7] << 17) | ((int64_t)p[8] << 9) |
                          ((int64_t)p[9] << 1) | (p[10] >> 7);
            int64_t u = unwrap(d, pcr);
            d->ts_ref = u;
            if (d->cb.on_pcr)
                d->cb.on_pcr(d->cb.ctx, u);
        }
        off += 1 + al;
    }
    if (!(afc & 1) || off >= TS_SIZE)
        return;

    // continuity check
    int last = d->cc[pid];
    if (last >= 0) {
        if (cc == last)
            return;  // duplicate
        if (cc != ((last + 1) & 0x0F)) {
            d->stats.drops++;
            if (pid == d->video.pid)
                d->video.corrupt = true;
            else if (pid == d->audio.pid)
                d->audio.corrupt = true;
        }
    }
    d->cc[pid] = (int8_t)cc;

    if (scr) {
        d->stats.scrambled++;
        if (pid == d->video.pid)
            reset_pes(&d->video);
        else if (pid == d->audio.pid)
            reset_pes(&d->audio);
        return;
    }

    const uint8_t *pl = p + off;
    int n = TS_SIZE - off;
    if (pid == d->video.pid)
        feed_pes(d, &d->video, PES_VIDEO, pusi, pl, n);
    else if (pid == d->audio.pid)
        feed_pes(d, &d->audio, PES_AUDIO, pusi, pl, n);
    else if (pid == 0x00 || pid == d->pmt_pid || pid == 0x10 || pid == 0x11 || pid == 0x12 || pid == 0x14)
        feed_section(d, pid, pusi, pl, n);
}

void tv_demux_feed(tv_demux *d, const uint8_t *data, size_t len)
{
    size_t i = 0;
    if (d->residue_len > 0) {
        size_t need = TS_SIZE - (size_t)d->residue_len;
        if (len < need) {
            memcpy(d->residue + d->residue_len, data, len);
            d->residue_len += (int)len;
            return;
        }
        memcpy(d->residue + d->residue_len, data, need);
        d->residue_len = 0;
        if (d->residue[0] == 0x47)
            handle_packet(d, d->residue);
        i = need;
    }
    while (i < len) {
        if (data[i] != 0x47) {
            // resync: find 0x47 followed by 0x47 one packet later (when visible)
            size_t j = i + 1;
            while (j < len && !(data[j] == 0x47 && (j + TS_SIZE >= len || data[j + TS_SIZE] == 0x47)))
                j++;
            i = j;
            continue;
        }
        if (len - i < TS_SIZE) {
            memcpy(d->residue, data + i, len - i);
            d->residue_len = (int)(len - i);
            return;
        }
        handle_packet(d, data + i);
        i += TS_SIZE;
    }
}
