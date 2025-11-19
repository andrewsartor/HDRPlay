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

// Helper function declarations
int get_averror_eof(void);
int averror_from_errno(int err);
int get_averror_eagain(void);
extern const int64_t AV_NOPTS_VALUE_INT;

// Side data helper - get from codecpar
const AVPacketSideData* get_codec_side_data(const AVCodecParameters *codecpar, enum AVPacketSideDataType type);

#endif // !CFFmpeg_h
