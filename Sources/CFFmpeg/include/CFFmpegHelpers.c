//
//  CFFmpegHelpers.c
//  hdrplay
//
//  Created by Andrew Sartor on 2025/11/18.
//

#include "CFFmpeg.h"

int get_averror_eof(void) {
    return AVERROR_EOF;
}

int averror_from_errno(int err) {
    return AVERROR(err);
}

int get_averror_eagain(void) {
    return AVERROR(EAGAIN);
}

const int64_t AV_NOPTS_VALUE_INT = AV_NOPTS_VALUE;
