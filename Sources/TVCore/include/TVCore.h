// SPDX-License-Identifier: GPL-2.0-or-later
// TVCore: BonDriverProxy(Ex) client + MPEG-2 TS demuxer + FFmpeg decoders.
// Produces ready-to-enqueue CMSampleBuffers for AVSampleBufferDisplayLayer /
// AVSampleBufferAudioRenderer.
#ifndef TVCORE_H
#define TVCORE_H

#include <stdint.h>
#include <stdbool.h>
#include <CoreMedia/CoreMedia.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct tv_session tv_session;

typedef enum {
    TV_EV_SERVICES = 1,  // JSON: {"onid","tsid","nid","tsname","remote_key","services":[{"sid","name","type"}]}
    TV_EV_PROGRAM  = 2,  // JSON: {"sid","present":{"title","text","start","duration"},"following":{...}}
    TV_EV_STATUS   = 3,  // JSON: {"signal","bitrate","scrambled","drops","vqueue","aqueue"}
    TV_EV_STREAM   = 4,  // JSON: {"sid","video","width","height","audio","channels"}
    TV_EV_TUNED    = 5,  // JSON: {"ok":bool,"result":n,"ms":n,"gen":n}
    TV_EV_ERROR    = 6,  // JSON: {"msg"}
    TV_EV_CLOSED   = 7,  // connection closed
    TV_EV_TIME     = 8,  // JSON: {"utc":unix seconds}  (TOT/TDT)
    TV_EV_FORMAT   = 9,  // JSON: decoded format {"kind":"video"|"audio",...}
    // JSON: one EIT section (p/f or schedule, any service), sent once per section version per tune:
    // {"onid","tsid","sid","tid","ver","sec","seg_last","last_tid",
    //  "events":[{"id","start","dur","ca","title","text","genre":[],"ext":[[item,text]],
    //             "group":[[sid,eid]],"video","audio":[]}]}  (optional keys omitted when absent)
    TV_EV_EIT      = 10,
} tv_event_type;

typedef struct {
    void *ctx;
    // Called on decoder threads. Callee must CFRetain if it keeps the buffer.
    void (*on_video)(void *ctx, CMSampleBufferRef sb, uint32_t gen);
    void (*on_audio)(void *ctx, CMSampleBufferRef sb, uint32_t gen);
    // Unwrapped PCR of the selected service in 90kHz units (network thread, ~10Hz).
    void (*on_clock)(void *ctx, int64_t pcr90k, uint32_t gen);
    // Called on the network thread.
    void (*on_event)(void *ctx, int type, const char *json);
} tv_callbacks;

tv_session *tv_session_create(tv_callbacks cb);
void tv_session_destroy(tv_session *s);

// Connect + SelectBonDriver(group) + CreateBonDriver + OpenTuner. Returns 0 on success.
int tv_session_open(tv_session *s, const char *host, int port, const char *group);
void tv_session_close(tv_session *s);
bool tv_session_is_open(tv_session *s);

// Tuning-space / channel enumeration (blocking). Returns malloc'ed UTF-8 or NULL.
char *tv_session_enum_space(tv_session *s, uint32_t space);
char *tv_session_enum_channel(tv_session *s, uint32_t space, uint32_t ch);

// Blocking SetChannel2. sid == 0 selects the first TV service.
// Returns server result (0 = ok, 1 = locked by another client, 0xff = failed) or -1 on I/O error.
int tv_session_set_channel(tv_session *s, uint32_t space, uint32_t ch, uint16_t sid, int lock_priority);

// Switch service inside the current TS (no retune).
void tv_session_select_service(tv_session *s, uint16_t sid);
// Audio: index of audio ES in the PMT; dual-mono: 0 = stereo/main, 1 = left, 2 = right.
void tv_session_set_audio(tv_session *s, int es_index, int dual_mono_mode);
void tv_session_set_deinterlace(tv_session *s, bool on);
// Bitmask: 1 = request server-side B25 descrambling (eDesireToUseB25).
void tv_session_set_options(tv_session *s, int opts);

uint32_t tv_session_generation(tv_session *s);
// Raw TS recording of the received stream (all services). Returns 0 on success.
int tv_session_record_start(tv_session *s, const char *path);
// Returns the number of bytes written.
uint64_t tv_session_record_stop(tv_session *s);
bool tv_session_is_recording(tv_session *s);

// Latest signal level (C/N dB) reported by the server.
float tv_session_signal_level(tv_session *s);

// Free strings returned by the API.
void tv_free(void *p);

#ifdef __cplusplus
}
#endif
#endif
