//
//  CFFmpeg.h
//  hdrplay
//
//  Created by Andrew Sartor on 2025/11/18.
//


#ifndef CFFmpeg_h
#define CFFmpeg_h

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/error.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libavutil/mastering_display_metadata.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

static inline int get_averror_eof(void) {
    return AVERROR_EOF;
}

static const int64_t AV_NOPTS_VALUE_INT = AV_NOPTS_VALUE;

static inline int averror_from_errno(int err) {
    return AVERROR(err);
}

#endif // !CFFmpeg_h
