// SPDX-License-Identifier: GPL-2.0-or-later
// Command line smoke test for TVCore:
//   tvprobe <host> <group> <space> <channel> [seconds] [sid]
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "TVCore.h"

static atomic_int nvideo, naudio;
static int64_t first_v = -1, last_v, first_a = -1, last_a, first_pcr = -1, last_pcr;
static uint32_t cur_gen;

static void on_video(void *ctx, CMSampleBufferRef sb, uint32_t gen)
{
    (void)ctx;
    if (gen != cur_gen)
        return;
    CMTime t = CMSampleBufferGetPresentationTimeStamp(sb);
    int64_t v = CMTimeConvertScale(t, 90000, kCMTimeRoundingMethod_Default).value;
    if (first_v < 0)
        first_v = v;
    last_v = v;
    if (atomic_fetch_add(&nvideo, 1) < 3)
        printf("  video pts %.3f (pcr %.3f)\n", v / 90000.0, last_pcr / 90000.0);
}

static void on_audio(void *ctx, CMSampleBufferRef sb, uint32_t gen)
{
    (void)ctx;
    if (gen != cur_gen)
        return;
    CMTime t = CMSampleBufferGetPresentationTimeStamp(sb);
    int64_t v = CMTimeConvertScale(t, 90000, kCMTimeRoundingMethod_Default).value;
    if (first_a < 0)
        first_a = v;
    last_a = v;
    if (atomic_fetch_add(&naudio, 1) < 3)
        printf("  audio pts %.3f (pcr %.3f)\n", v / 90000.0, last_pcr / 90000.0);
}

#include <time.h>
static double wall(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static double off_min=1e18, off_max=-1e18, off_last_print=0;
static void on_clock(void *ctx, int64_t pcr, uint32_t gen)
{
    (void)ctx;
    if (getenv("PCRDUMP")) {
        static double t0 = 0;
        if (t0 == 0) t0 = wall();
        if (wall() - t0 > 3 && wall() - t0 < 6)
            printf("  t=%.3f pcr=%.3f off=%.3f\n", wall() - t0, pcr / 90000.0, pcr / 90000.0 - wall());
    }
    if (getenv("PCRJIT")) {
        double o = pcr / 90000.0 - wall();
        if (o < off_min) off_min = o;
        if (o > off_max) off_max = o;
        if (wall() - off_last_print > 1) {
            printf("  pcr-wall range %.3f..%.3f (%.0f ms)\n", off_min, off_max, (off_max - off_min) * 1000);
            off_last_print = wall(); off_min = 1e18; off_max = -1e18;
        }
    }
    if (gen == cur_gen && first_pcr >= 0 && llabs(pcr - last_pcr) > 900000)
        printf("  !! PCR jump within gen %u: %.3f -> %.3f\n", gen, last_pcr / 90000.0, pcr / 90000.0);
    cur_gen = gen;
    if (first_pcr < 0) {
        first_pcr = pcr;
        printf("  first pcr %.3f gen %u\n", pcr / 90000.0, gen);
    }
    last_pcr = pcr;
}

static int eit_sections, eit_samples;
static int eit_by_tid[256];

static void on_event(void *ctx, int type, const char *json)
{
    (void)ctx;
    if (type == TV_EV_EIT) {
        // EIT floods the console; count it and show a few sections with events (EITDUMP=n for more)
        const char *t = strstr(json, "\"tid\":");
        if (t)
            eit_by_tid[atoi(t + 6) & 0xFF]++;
        eit_sections++;
        int limit = getenv("EITDUMP") ? atoi(getenv("EITDUMP")) : 2;
        if (strstr(json, "\"title\"") && eit_samples < limit) {
            eit_samples++;
            printf("[eit] %s\n", json);
        }
        return;
    }
    if (type == TV_EV_STATUS)
        printf("[status] %s v=%d a=%d (v-pcr %+.3fs, a-pcr %+.3fs)\n", json, nvideo, naudio,
               (last_v - last_pcr) / 90000.0, (last_a - last_pcr) / 90000.0);
    else
        printf("[%d] %s\n", type, json);
    fflush(stdout);
}

int main(int argc, char **argv)
{
    if (argc < 5) {
        fprintf(stderr, "usage: %s host group space channel [seconds] [sid]\n", argv[0]);
        return 1;
    }
    int secs = argc > 5 ? atoi(argv[5]) : 5;
    int sid = argc > 6 ? atoi(argv[6]) : 0;
    tv_callbacks cb = {NULL, on_video, on_audio, on_clock, on_event};
    tv_session *s = tv_session_create(cb);
    int rc = tv_session_open(s, argv[1], 1192, argv[2]);
    printf("open -> %d\n", rc);
    if (rc != 0)
        return 1;
    char *sp = tv_session_enum_space(s, (uint32_t)atoi(argv[3]));
    char *ch = tv_session_enum_channel(s, (uint32_t)atoi(argv[3]), (uint32_t)atoi(argv[4]));
    printf("space=%s channel=%s\n", sp ? sp : "-", ch ? ch : "-");
    tv_free(sp);
    tv_free(ch);
    cur_gen = tv_session_generation(s) + 1;
    int r = tv_session_set_channel(s, (uint32_t)atoi(argv[3]), (uint32_t)atoi(argv[4]), (uint16_t)sid, 0);
    printf("set_channel -> %d\n", r);
    cur_gen = tv_session_generation(s);
    if (getenv("REC"))  // REC=path: also save the raw TS
        printf("record -> %d\n", tv_session_record_start(s, getenv("REC")));
    sleep((unsigned)secs);
    if (tv_session_is_recording(s))
        printf("recorded %llu bytes\n", (unsigned long long)tv_session_record_stop(s));
    for (int ai = 7; ai < argc; ai++) {
        int ch2 = atoi(argv[ai]);
        nvideo = naudio = 0;
        first_v = first_a = first_pcr = -1;
        cur_gen = tv_session_generation(s) + 1;
        r = tv_session_set_channel(s, (uint32_t)atoi(argv[3]), (uint32_t)ch2, 0, 0);
        printf("set_channel(%d) -> %d\n", ch2, r);
        sleep((unsigned)secs);
    }
    if (eit_sections) {
        printf("EIT sections %d:", eit_sections);
        for (int i = 0; i < 256; i++)
            if (eit_by_tid[i])
                printf(" 0x%02X=%d", i, eit_by_tid[i]);
        printf("\n");
    }
    printf("video frames %d (%.2f fps), audio buffers %d\n", nvideo,
           nvideo / ((last_v - first_v) / 90000.0 + 1e-9), naudio);
    tv_session_destroy(s);
    return 0;
}
