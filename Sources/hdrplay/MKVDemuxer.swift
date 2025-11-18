//
//  MKVDemuxer.swift
//  hdrplay
//
//  Created by Andrew Sartor on 2025/11/18.
//

import Foundation
import CFFmpeg
import AVFoundation

public class MKVDemuxer {
    private var formatContext: UnsafeMutablePointer<CFFmpeg.AVFormatContext>?
    private var videoStreamIndex: Int = -1
    private var videoStream: UnsafeMutablePointer<CFFmpeg.AVStream>?
    
    public init(url: URL) throws {
        var ctx: UnsafeMutablePointer<CFFmpeg.AVFormatContext>?
        
        let result = avformat_open_input(&ctx, url.path, nil, nil)
        guard result == 0 else {
            throw DemuxerError.cannotOpenFile(code: result)
        }
        
        self.formatContext = ctx
        
        guard avformat_find_stream_info(formatContext, nil) >= 0 else {
            throw DemuxerError.cannotFindStreamInfo
        }
        
        try findVideoStream()
        
        print("✅ Opened: \(url.lastPathComponent)")
    }
    
    private func findVideoStream() throws {
        guard let formatContext = formatContext else {
            throw DemuxerError.InvalidContext
        }
        
        for i in 0..<Int(formatContext.pointee.nb_streams) {
            let stream = formatContext.pointee.streams[i]!
            let codecPar = stream.pointee.codecpar.pointee
            
            if codecPar.codec_type == AVMEDIA_TYPE_VIDEO {
                videoStreamIndex = i
                videoStream = stream
                return
            }
        }
        
        throw DemuxerError.noVideoStream
    }
    
    public var videoInfo: VideoInfo? {
        guard let stream = videoStream else { return nil }
        let codecPar = stream.pointee.codecpar.pointee

        // Extract extradata if available
        var extradata: Data?
        if codecPar.extradata_size > 0, let extradataPtr = codecPar.extradata {
            extradata = Data(bytes: extradataPtr, count: Int(codecPar.extradata_size))
        }

        return VideoInfo(
            width: Int(codecPar.width),
            height: Int(codecPar.height),
            codecID: codecPar.codec_id,
            colorTransfer: codecPar.color_trc,
            colorPrimaries: codecPar.color_primaries,
            extradata: extradata,
            pixelFormat: AVPixelFormat(codecPar.format)
        )
    }

    public var timebase: AVRational? {
        guard let stream = videoStream else { return nil }
        return stream.pointee.time_base
    }
    
    public func readPacket() throws -> VideoPacket? {
        guard let formatContext = formatContext else {
            throw DemuxerError.InvalidContext
        }
        
        var packet: UnsafeMutablePointer<CFFmpeg.AVPacket>? = av_packet_alloc()
        guard let pkt = packet else {
            throw DemuxerError.cannotOpenFile(code: -1)
        }
        
        while true {
            let result = av_read_frame(formatContext, pkt)
            
            if result < 0 {
                av_packet_free(&packet)
                if result == get_averror_eof() {
                    return nil
                }
                throw DemuxerError.cannotOpenFile(code: result)
            }
            
            if Int(pkt.pointee.stream_index) == videoStreamIndex {
                let data = Data(bytes: pkt.pointee.data, count: Int(pkt.pointee.size))
                let timebase = videoStream!.pointee.time_base
                
                let vpacket = VideoPacket(data: data, pts: pkt.pointee.pts, dts: pkt.pointee.dts, duration: pkt.pointee.duration, timebase: timebase, isKeyframe: (pkt.pointee.flags & AV_PKT_FLAG_KEY) != 0)
                
                av_packet_unref(pkt)
                av_packet_free(&packet)
                return vpacket
            }
            
            av_packet_unref(pkt)
        }
    }
    
    public var duration: Double? {
        guard let formatContext = formatContext,
              formatContext.pointee.duration != AV_NOPTS_VALUE_INT else {
            return nil
        }
        return Double(formatContext.pointee.duration) / Double(AV_TIME_BASE)
    }
    
    deinit {
        if formatContext != nil {
            avformat_close_input(&formatContext)
        }
    }
}

public enum DemuxerError: Error {
    case cannotOpenFile(code: Int32)
    case cannotFindStreamInfo
    case InvalidContext
    case noVideoStream
}

public struct VideoInfo {
    public let width: Int
    public let height: Int
    public let codecID: AVCodecID
    public let colorTransfer: AVColorTransferCharacteristic
    public let colorPrimaries: AVColorPrimaries
    public let extradata: Data?
    public let pixelFormat: AVPixelFormat

    public var isHDR10: Bool {
        colorTransfer == AVCOL_TRC_SMPTE2084 && colorPrimaries == AVCOL_PRI_BT2020
    }

    public var isHLG: Bool {
        colorTransfer == AVCOL_TRC_ARIB_STD_B67
    }
}

public struct VideoPacket {
    public let data: Data
    public let pts: Int64
    public let dts: Int64
    public let duration: Int64
    public let timebase: CFFmpeg.AVRational
    public let isKeyframe: Bool
}

