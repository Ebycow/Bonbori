// SPDX-License-Identifier: GPL-2.0-or-later
// FFmpeg based decoders running on their own threads.
// Video: libavcodec (+ bwdif field-rate deinterlace) -> NV12 IOSurface CVPixelBuffer -> CMSampleBuffer
// Audio: libavcodec -> float32 stereo interleaved -> CMSampleBuffer (LPCM)
#include "internal.h"
#include "TVCore.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

typedef struct qpkt {
    struct qpkt *next;
    int stream_type;
    int64_t pts, dts;
    uint32_t gen;
    size_t len;
    uint8_t data[];
} qpkt;

struct tv_decoder {
    int kind;
    tv_decoder_cb cb;

    pthread_t thread;
    pthread_mutex_t mtx;
    pthread_cond_t cond;
    qpkt *head, *tail;
    int qlen;
    bool quit;
    bool need_flush;
    uint32_t flush_gen;

    atomic_bool deinterlace;
    atomic_int dual_mono;

    // codec state (decoder thread only)
    int stream_type;
    AVCodecContext *avctx;
    AVCodecParserContext *parser;
    AVPacket *pkt;
    AVFrame *frame;
    AVFrame *ffr;
    uint32_t cur_gen;

    // video
    bool seen_key;
    AVFilterGraph *graph;
    AVFilterContext *src_ctx, *sink_ctx;
    int g_w, g_h, g_fmt, g_csp, g_range;
    AVRational g_sar;
    bool g_deint;
    struct SwsContext *sws;
    int s_w, s_h, s_fmt;
    CVPixelBufferPoolRef pool;
    int p_w, p_h;
    CMVideoFormatDescriptionRef vfmt;
    int info_w, info_h, info_sar_n, info_sar_d, info_il;

    // audio
    SwrContext *swr;
    AVChannelLayout swr_in_layout;
    int swr_in_rate, swr_in_fmt;
    CMAudioFormatDescriptionRef afmt;
    int afmt_rate;
    int64_t next_apts;
    float *abuf;
    int abuf_cap;
    int info_ch, info_rate;
};

// ----------------------------------------------------------------- queue
void tv_decoder_push(tv_decoder *d, int stream_type, const uint8_t *data, size_t len, int64_t pts,
                     int64_t dts, uint32_t gen)
{
    qpkt *p = malloc(sizeof(qpkt) + len + AV_INPUT_BUFFER_PADDING_SIZE);
    p->next = NULL;
    p->stream_type = stream_type;
    p->pts = pts;
    p->dts = dts;
    p->gen = gen;
    p->len = len;
    memcpy(p->data, data, len);
    memset(p->data + len, 0, AV_INPUT_BUFFER_PADDING_SIZE);

    pthread_mutex_lock(&d->mtx);
    if (d->tail)
        d->tail->next = p;
    else
        d->head = p;
    d->tail = p;
    d->qlen++;
    // never let the queue explode (e.g. decoder stalled)
    int limit = d->kind == PES_VIDEO ? 300 : 600;
    while (d->qlen > limit) {
        qpkt *o = d->head;
        d->head = o->next;
        if (!d->head)
            d->tail = NULL;
        d->qlen--;
        free(o);
    }
    pthread_cond_signal(&d->cond);
    pthread_mutex_unlock(&d->mtx);
}

static void queue_clear_locked(tv_decoder *d)
{
    while (d->head) {
        qpkt *o = d->head;
        d->head = o->next;
        free(o);
    }
    d->tail = NULL;
    d->qlen = 0;
}

void tv_decoder_flush(tv_decoder *d, uint32_t gen)
{
    pthread_mutex_lock(&d->mtx);
    queue_clear_locked(d);
    d->need_flush = true;
    d->flush_gen = gen;
    pthread_cond_signal(&d->cond);
    pthread_mutex_unlock(&d->mtx);
}

int tv_decoder_queue_len(tv_decoder *d)
{
    pthread_mutex_lock(&d->mtx);
    int n = d->qlen;
    pthread_mutex_unlock(&d->mtx);
    return n;
}

void tv_decoder_set_deinterlace(tv_decoder *d, bool on)
{
    atomic_store(&d->deinterlace, on);
}

void tv_decoder_set_dual_mono(tv_decoder *d, int mode)
{
    atomic_store(&d->dual_mono, mode);
}

// ----------------------------------------------------------------- codec setup
static void free_graph(tv_decoder *d)
{
    if (d->graph)
        avfilter_graph_free(&d->graph);
    d->graph = NULL;
    d->src_ctx = d->sink_ctx = NULL;
}

static void close_codec(tv_decoder *d)
{
    if (d->parser)
        av_parser_close(d->parser);
    d->parser = NULL;
    if (d->avctx)
        avcodec_free_context(&d->avctx);
    free_graph(d);
    d->stream_type = -1;
}

static enum AVCodecID codec_for(int kind, int st)
{
    if (kind == PES_VIDEO) {
        switch (st) {
        case 0x01: return AV_CODEC_ID_MPEG1VIDEO;
        case 0x02: return AV_CODEC_ID_MPEG2VIDEO;
        case 0x1B: return AV_CODEC_ID_H264;
        case 0x24: return AV_CODEC_ID_HEVC;
        }
    } else {
        switch (st) {
        case 0x0F: return AV_CODEC_ID_AAC;
        case 0x11: return AV_CODEC_ID_AAC_LATM;
        case 0x03: return AV_CODEC_ID_MP2;
        case 0x04: return AV_CODEC_ID_MP3;
        }
    }
    return AV_CODEC_ID_NONE;
}

static bool open_codec(tv_decoder *d, int st)
{
    close_codec(d);
    enum AVCodecID id = codec_for(d->kind, st);
    if (id == AV_CODEC_ID_NONE)
        return false;
    const AVCodec *codec = avcodec_find_decoder(id);
    if (!codec)
        return false;
    d->avctx = avcodec_alloc_context3(codec);
    if (d->kind == PES_VIDEO) {
        d->avctx->thread_count = 4;
        // Slice threads only: frame threading adds a frame of latency per thread.
        // (No AV_CODEC_FLAG_LOW_DELAY: it disables B-frame reordering in the MPEG-2 decoder.)
        d->avctx->thread_type = FF_THREAD_SLICE;
    }
    d->avctx->pkt_timebase = (AVRational){1, 90000};
    if (avcodec_open2(d->avctx, codec, NULL) < 0) {
        avcodec_free_context(&d->avctx);
        return false;
    }
    d->parser = av_parser_init(id);
    d->stream_type = st;
    d->seen_key = false;
    d->next_apts = TV_NOPTS;
    return true;
}

static void reset_state(tv_decoder *d)
{
    if (d->avctx)
        avcodec_flush_buffers(d->avctx);
    if (d->parser) {
        av_parser_close(d->parser);
        d->parser = av_parser_init(codec_for(d->kind, d->stream_type));
    }
    free_graph(d);
    d->seen_key = false;
    d->next_apts = TV_NOPTS;
}

// ----------------------------------------------------------------- video output
static bool build_graph(tv_decoder *d, AVFrame *f)
{
    free_graph(d);
    d->graph = avfilter_graph_alloc();
    char args[256];
    AVRational sar = f->sample_aspect_ratio;
    if (sar.num <= 0 || sar.den <= 0)
        sar = (AVRational){1, 1};
    snprintf(args, sizeof(args), "video_size=%dx%d:pix_fmt=%d:time_base=1/90000:pixel_aspect=%d/%d", f->width,
             f->height, f->format, sar.num, sar.den);
    if (avfilter_graph_create_filter(&d->src_ctx, avfilter_get_by_name("buffer"), "in", args, NULL, d->graph) < 0)
        goto fail;
    AVBufferSrcParameters *bp = av_buffersrc_parameters_alloc();
    bp->format = f->format;
    bp->width = f->width;
    bp->height = f->height;
    bp->time_base = (AVRational){1, 90000};
    bp->sample_aspect_ratio = sar;
    bp->color_space = f->colorspace;
    bp->color_range = f->color_range;
    av_buffersrc_parameters_set(d->src_ctx, bp);
    av_free(bp);
    if (avfilter_graph_create_filter(&d->sink_ctx, avfilter_get_by_name("buffersink"), "out", NULL, NULL,
                                     d->graph) < 0)
        goto fail;

    AVFilterInOut *outputs = avfilter_inout_alloc();
    AVFilterInOut *inputs = avfilter_inout_alloc();
    outputs->name = av_strdup("in");
    outputs->filter_ctx = d->src_ctx;
    outputs->pad_idx = 0;
    outputs->next = NULL;
    inputs->name = av_strdup("out");
    inputs->filter_ctx = d->sink_ctx;
    inputs->pad_idx = 0;
    inputs->next = NULL;
    int r = avfilter_graph_parse_ptr(d->graph, "bwdif=mode=send_field:parity=auto:deint=interlaced", &inputs,
                                     &outputs, NULL);
    avfilter_inout_free(&inputs);
    avfilter_inout_free(&outputs);
    if (r < 0 || avfilter_graph_config(d->graph, NULL) < 0)
        goto fail;
    d->g_w = f->width;
    d->g_h = f->height;
    d->g_fmt = f->format;
    d->g_sar = f->sample_aspect_ratio;
    d->g_csp = f->colorspace;
    d->g_range = f->color_range;
    return true;
fail:
    free_graph(d);
    return false;
}

static CVPixelBufferPoolRef make_pool(int w, int h)
{
    CFMutableDictionaryRef attrs =
        CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int fmt = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CFNumberRef nfmt = CFNumberCreate(NULL, kCFNumberIntType, &fmt);
    CFNumberRef nw = CFNumberCreate(NULL, kCFNumberIntType, &w);
    CFNumberRef nh = CFNumberCreate(NULL, kCFNumberIntType, &h);
    CFDictionaryRef ios =
        CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attrs, kCVPixelBufferPixelFormatTypeKey, nfmt);
    CFDictionarySetValue(attrs, kCVPixelBufferWidthKey, nw);
    CFDictionarySetValue(attrs, kCVPixelBufferHeightKey, nh);
    CFDictionarySetValue(attrs, kCVPixelBufferIOSurfacePropertiesKey, ios);
    CFDictionarySetValue(attrs, kCVPixelBufferMetalCompatibilityKey, kCFBooleanTrue);
    CVPixelBufferPoolRef pool = NULL;
    CVPixelBufferPoolCreate(NULL, NULL, attrs, &pool);
    CFRelease(ios);
    CFRelease(nh);
    CFRelease(nw);
    CFRelease(nfmt);
    CFRelease(attrs);
    return pool;
}

static void emit_video_info(tv_decoder *d, AVFrame *f, bool interlaced)
{
    AVRational sar = f->sample_aspect_ratio;
    if (sar.num <= 0 || sar.den <= 0)
        sar = (AVRational){1, 1};
    if (d->info_w == f->width && d->info_h == f->height && d->info_sar_n == sar.num && d->info_sar_d == sar.den &&
        (d->info_il == (int)interlaced || !interlaced))
        return;
    d->info_w = f->width;
    d->info_h = f->height;
    d->info_sar_n = sar.num;
    d->info_sar_d = sar.den;
    d->info_il = interlaced;
    char buf[256];
    snprintf(buf, sizeof(buf),
             "{\"kind\":\"video\",\"codec\":\"%s\",\"width\":%d,\"height\":%d,\"sar_num\":%d,\"sar_den\":%d,"
             "\"interlaced\":%s}",
             d->avctx ? avcodec_get_name(d->avctx->codec_id) : "?", f->width, f->height, sar.num, sar.den,
             interlaced ? "true" : "false");
    if (d->cb.on_info)
        d->cb.on_info(d->cb.ctx, PES_VIDEO, buf);
}

static void output_video(tv_decoder *d, AVFrame *f, int64_t pts90k, uint32_t gen)
{
    int w = f->width, h = f->height;
    if (!d->pool || d->p_w != w || d->p_h != h) {
        if (d->pool)
            CVPixelBufferPoolRelease(d->pool);
        d->pool = make_pool(w, h);
        d->p_w = w;
        d->p_h = h;
    }
    if (!d->sws || d->s_w != w || d->s_h != h || d->s_fmt != f->format) {
        if (d->sws)
            sws_freeContext(d->sws);
        d->sws = sws_getContext(w, h, f->format, w, h, AV_PIX_FMT_NV12, SWS_POINT, NULL, NULL, NULL);
        d->s_w = w;
        d->s_h = h;
        d->s_fmt = f->format;
    }
    if (!d->pool || !d->sws)
        return;
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, d->pool, &pb) != kCVReturnSuccess)
        return;
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *dst[4] = {CVPixelBufferGetBaseAddressOfPlane(pb, 0), CVPixelBufferGetBaseAddressOfPlane(pb, 1), NULL,
                       NULL};
    int dstride[4] = {(int)CVPixelBufferGetBytesPerRowOfPlane(pb, 0), (int)CVPixelBufferGetBytesPerRowOfPlane(pb, 1),
                      0, 0};
    sws_scale(d->sws, (const uint8_t *const *)f->data, f->linesize, 0, h, dst, dstride);
    CVPixelBufferUnlockBaseAddress(pb, 0);

    AVRational sar = f->sample_aspect_ratio;
    if (sar.num > 0 && sar.den > 0) {
        CFNumberRef hs = CFNumberCreate(NULL, kCFNumberIntType, &sar.num);
        CFNumberRef vs = CFNumberCreate(NULL, kCFNumberIntType, &sar.den);
        const void *keys[] = {kCVImageBufferPixelAspectRatioHorizontalSpacingKey,
                              kCVImageBufferPixelAspectRatioVerticalSpacingKey};
        const void *vals[] = {hs, vs};
        CFDictionaryRef par =
            CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CVBufferSetAttachment(pb, kCVImageBufferPixelAspectRatioKey, par, kCVAttachmentMode_ShouldPropagate);
        CFRelease(par);
        CFRelease(hs);
        CFRelease(vs);
    }
    bool hd = h > 576;
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey,
                          hd ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey,
                          hd ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_SMPTE_C,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);

    if (d->vfmt && !CMVideoFormatDescriptionMatchesImageBuffer(d->vfmt, pb)) {
        CFRelease(d->vfmt);
        d->vfmt = NULL;
    }
    if (!d->vfmt)
        CMVideoFormatDescriptionCreateForImageBuffer(NULL, pb, &d->vfmt);
    CMSampleTimingInfo ti = {kCMTimeInvalid, CMTimeMake(pts90k, 90000), kCMTimeInvalid};
    CMSampleBufferRef sb = NULL;
    if (d->vfmt && CMSampleBufferCreateReadyWithImageBuffer(NULL, pb, d->vfmt, &ti, &sb) == noErr) {
        if (d->cb.on_video)
            d->cb.on_video(d->cb.ctx, sb, gen);
        CFRelease(sb);
    }
    CVPixelBufferRelease(pb);
}

static int64_t frame_pts(AVFrame *f)
{
    if (f->pts != AV_NOPTS_VALUE)
        return f->pts;
    if (f->best_effort_timestamp != AV_NOPTS_VALUE)
        return f->best_effort_timestamp;
    return TV_NOPTS;
}

static void handle_video_frame(tv_decoder *d, AVFrame *f, uint32_t gen)
{
    if (!d->seen_key) {
        if (!(f->flags & AV_FRAME_FLAG_KEY) && f->pict_type != AV_PICTURE_TYPE_I)
            return;
        d->seen_key = true;
    }
    int64_t pts = frame_pts(f);
    if (pts == TV_NOPTS)
        return;
    bool interlaced = (f->flags & AV_FRAME_FLAG_INTERLACED) != 0;
    emit_video_info(d, f, interlaced);

    bool deint = atomic_load(&d->deinterlace);
    if (!deint) {
        free_graph(d);
        output_video(d, f, pts, gen);
        return;
    }
    if (!d->graph || d->g_w != f->width || d->g_h != f->height || d->g_fmt != f->format ||
        av_cmp_q(d->g_sar, f->sample_aspect_ratio) != 0 || d->g_csp != (int)f->colorspace ||
        d->g_range != (int)f->color_range) {
        if (!build_graph(d, f)) {
            output_video(d, f, pts, gen);
            return;
        }
    }
    f->pts = pts;
    if (av_buffersrc_add_frame_flags(d->src_ctx, f, AV_BUFFERSRC_FLAG_KEEP_REF) < 0)
        return;
    AVRational tb = av_buffersink_get_time_base(d->sink_ctx);
    while (av_buffersink_get_frame(d->sink_ctx, d->ffr) >= 0) {
        if (d->ffr->pts != AV_NOPTS_VALUE)
            output_video(d, d->ffr, av_rescale_q(d->ffr->pts, tb, (AVRational){1, 90000}), gen);
        av_frame_unref(d->ffr);
    }
}

// ----------------------------------------------------------------- audio output
static void emit_audio_info(tv_decoder *d, AVFrame *f)
{
    int ch = f->ch_layout.nb_channels;
    if (d->info_ch == ch && d->info_rate == f->sample_rate)
        return;
    d->info_ch = ch;
    d->info_rate = f->sample_rate;
    char lay[64] = "";
    av_channel_layout_describe(&f->ch_layout, lay, sizeof(lay));
    char buf[256];
    snprintf(buf, sizeof(buf), "{\"kind\":\"audio\",\"codec\":\"%s\",\"channels\":%d,\"rate\":%d,\"layout\":\"%s\"}",
             d->avctx ? avcodec_get_name(d->avctx->codec_id) : "?", ch, f->sample_rate, lay);
    if (d->cb.on_info)
        d->cb.on_info(d->cb.ctx, PES_AUDIO, buf);
}

static void handle_audio_frame(tv_decoder *d, AVFrame *f, uint32_t gen)
{
    int rate = f->sample_rate;
    if (rate <= 0 || f->nb_samples <= 0)
        return;
    emit_audio_info(d, f);
    if (!d->swr || d->swr_in_rate != rate || d->swr_in_fmt != f->format ||
        av_channel_layout_compare(&d->swr_in_layout, &f->ch_layout) != 0) {
        swr_free(&d->swr);
        AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
        if (swr_alloc_set_opts2(&d->swr, &stereo, AV_SAMPLE_FMT_FLT, rate, &f->ch_layout, f->format, rate, 0,
                                NULL) < 0 ||
            swr_init(d->swr) < 0) {
            swr_free(&d->swr);
            return;
        }
        av_channel_layout_uninit(&d->swr_in_layout);
        av_channel_layout_copy(&d->swr_in_layout, &f->ch_layout);
        d->swr_in_rate = rate;
        d->swr_in_fmt = f->format;
    }
    int cap = f->nb_samples + 256;
    if (d->abuf_cap < cap) {
        d->abuf = realloc(d->abuf, (size_t)cap * 2 * sizeof(float));
        d->abuf_cap = cap;
    }
    uint8_t *out[1] = {(uint8_t *)d->abuf};
    int n = swr_convert(d->swr, out, cap, (const uint8_t *const *)f->extended_data, f->nb_samples);
    if (n <= 0)
        return;

    int dm = atomic_load(&d->dual_mono);
    if (dm == 1 || dm == 2) {
        for (int i = 0; i < n; i++) {
            float v = d->abuf[i * 2 + (dm - 1)];
            d->abuf[i * 2] = d->abuf[i * 2 + 1] = v;
        }
    }

    int64_t pts = frame_pts(f);
    if (d->next_apts != TV_NOPTS && (pts == TV_NOPTS || llabs(pts - d->next_apts) < 90000 / 5))  // 200ms, as LibISDB's MAX_JITTER
        pts = d->next_apts;
    if (pts == TV_NOPTS)
        return;
    d->next_apts = pts + (int64_t)n * 90000 / rate;

    if (!d->afmt || d->afmt_rate != rate) {
        if (d->afmt)
            CFRelease(d->afmt);
        AudioStreamBasicDescription asbd = {0};
        asbd.mSampleRate = rate;
        asbd.mFormatID = kAudioFormatLinearPCM;
        asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        asbd.mBytesPerPacket = 8;
        asbd.mFramesPerPacket = 1;
        asbd.mBytesPerFrame = 8;
        asbd.mChannelsPerFrame = 2;
        asbd.mBitsPerChannel = 32;
        AudioChannelLayout acl = {0};
        acl.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
        d->afmt = NULL;
        CMAudioFormatDescriptionCreate(NULL, &asbd, sizeof(acl), &acl, 0, NULL, NULL, &d->afmt);
        d->afmt_rate = rate;
    }
    if (!d->afmt)
        return;
    size_t bytes = (size_t)n * 8;
    CMBlockBufferRef bb = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(NULL, NULL, bytes, NULL, NULL, 0, bytes, kCMBlockBufferAssureMemoryNowFlag,
                                           &bb) != noErr)
        return;
    CMBlockBufferReplaceDataBytes(d->abuf, bb, 0, bytes);
    CMSampleBufferRef sb = NULL;
    // Use the sample rate as timescale so consecutive buffers are sample-exact.
    CMTime t = CMTimeConvertScale(CMTimeMake(pts, 90000), rate, kCMTimeRoundingMethod_Default);
    if (CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL, bb, d->afmt, n, t, NULL, &sb) == noErr) {
        if (d->cb.on_audio)
            d->cb.on_audio(d->cb.ctx, sb, gen);
        CFRelease(sb);
    }
    CFRelease(bb);
}

// ----------------------------------------------------------------- decode loop
static void decode_packet(tv_decoder *d, AVPacket *pkt, uint32_t gen)
{
    if (avcodec_send_packet(d->avctx, pkt) < 0)
        return;
    for (;;) {
        int r = avcodec_receive_frame(d->avctx, d->frame);
        if (r < 0)
            break;
        if (d->kind == PES_VIDEO)
            handle_video_frame(d, d->frame, gen);
        else
            handle_audio_frame(d, d->frame, gen);
        av_frame_unref(d->frame);
    }
}

static void process(tv_decoder *d, qpkt *q)
{
    if (q->stream_type != d->stream_type || !d->avctx) {
        if (!open_codec(d, q->stream_type))
            return;
    }
    int64_t pts = q->pts == TV_NOPTS ? AV_NOPTS_VALUE : q->pts;
    int64_t dts = q->dts == TV_NOPTS ? AV_NOPTS_VALUE : q->dts;
    if (!d->parser) {
        d->pkt->data = q->data;
        d->pkt->size = (int)q->len;
        d->pkt->pts = pts;
        d->pkt->dts = dts;
        decode_packet(d, d->pkt, q->gen);
        return;
    }
    const uint8_t *p = q->data;
    int left = (int)q->len;
    while (left > 0) {
        uint8_t *out = NULL;
        int outsz = 0;
        int used = av_parser_parse2(d->parser, d->avctx, &out, &outsz, p, left, pts, dts, 0);
        if (used < 0)
            break;
        p += used;
        left -= used;
        pts = dts = AV_NOPTS_VALUE;
        if (outsz > 0) {
            d->pkt->data = out;
            d->pkt->size = outsz;
            d->pkt->pts = d->parser->pts;
            d->pkt->dts = d->parser->dts;
            d->pkt->flags = d->parser->key_frame == 1 ? AV_PKT_FLAG_KEY : 0;
            decode_packet(d, d->pkt, q->gen);
        }
    }
}

static void *decoder_thread(void *arg)
{
    tv_decoder *d = arg;
    pthread_setname_np(d->kind == PES_VIDEO ? "tv.video" : "tv.audio");
    for (;;) {
        pthread_mutex_lock(&d->mtx);
        while (!d->quit && !d->head && !d->need_flush)
            pthread_cond_wait(&d->cond, &d->mtx);
        if (d->quit) {
            pthread_mutex_unlock(&d->mtx);
            break;
        }
        bool flush = d->need_flush;
        uint32_t fgen = d->flush_gen;
        d->need_flush = false;
        qpkt *q = NULL;
        if (!flush) {
            q = d->head;
            if (q) {
                d->head = q->next;
                if (!d->head)
                    d->tail = NULL;
                d->qlen--;
            }
        }
        pthread_mutex_unlock(&d->mtx);

        if (flush) {
            reset_state(d);
            d->cur_gen = fgen;
            continue;
        }
        if (!q)
            continue;
        if (q->gen == d->cur_gen)
            process(d, q);
        free(q);
    }
    return NULL;
}

tv_decoder *tv_decoder_create(int kind, tv_decoder_cb cb)
{
    tv_decoder *d = calloc(1, sizeof(*d));
    d->kind = kind;
    d->cb = cb;
    d->stream_type = -1;
    d->next_apts = TV_NOPTS;
    atomic_init(&d->deinterlace, true);
    atomic_init(&d->dual_mono, 0);
    d->pkt = av_packet_alloc();
    d->frame = av_frame_alloc();
    d->ffr = av_frame_alloc();
    pthread_mutex_init(&d->mtx, NULL);
    pthread_cond_init(&d->cond, NULL);
    pthread_create(&d->thread, NULL, decoder_thread, d);
    return d;
}

void tv_decoder_destroy(tv_decoder *d)
{
    if (!d)
        return;
    pthread_mutex_lock(&d->mtx);
    d->quit = true;
    pthread_cond_signal(&d->cond);
    pthread_mutex_unlock(&d->mtx);
    pthread_join(d->thread, NULL);
    queue_clear_locked(d);
    close_codec(d);
    if (d->sws)
        sws_freeContext(d->sws);
    if (d->pool)
        CVPixelBufferPoolRelease(d->pool);
    if (d->vfmt)
        CFRelease(d->vfmt);
    if (d->afmt)
        CFRelease(d->afmt);
    swr_free(&d->swr);
    av_channel_layout_uninit(&d->swr_in_layout);
    av_packet_free(&d->pkt);
    av_frame_free(&d->frame);
    av_frame_free(&d->ffr);
    free(d->abuf);
    pthread_mutex_destroy(&d->mtx);
    pthread_cond_destroy(&d->cond);
    free(d);
}
