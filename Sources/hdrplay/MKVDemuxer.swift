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
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private var videoStreamIndex: Int = -1
    private var videoStream: UnsafeMutablePointer<AVStream>?
    
    public init(url: URL) throws {
        var ctx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        
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

        // Extract mastering display metadata (SMPTE ST 2086) if available
        var masteringDisplayMetadata: MasteringDisplayMetadata?
        let sideDataPtr = get_codec_side_data(
            stream.pointee.codecpar,
            AV_PKT_DATA_MASTERING_DISPLAY_METADATA
        )

        print("🔍 Checking for SMPTE ST 2086 metadata in codecpar...")
        print("   Number of side data entries: \(stream.pointee.codecpar.pointee.nb_coded_side_data)")

        if let sideData = sideDataPtr {
            print("   ✅ Found mastering display metadata in codecpar")
            let metadata = sideData.pointee.data.withMemoryRebound(
                to: AVMasteringDisplayMetadata.self,
                capacity: 1
            ) { ptr in
                return ptr.pointee
            }

            // Check if metadata has values (not initialized to 0)
            if metadata.has_primaries != 0 || metadata.has_luminance != 0 {
                // Convert rational values to proper format
                // Use Int64 for intermediate calculations to avoid overflow
                let rx = UInt16(Int64(metadata.display_primaries.0.0.num) * 50000 / Int64(metadata.display_primaries.0.0.den))
                let ry = UInt16(Int64(metadata.display_primaries.0.1.num) * 50000 / Int64(metadata.display_primaries.0.1.den))
                let gx = UInt16(Int64(metadata.display_primaries.1.0.num) * 50000 / Int64(metadata.display_primaries.1.0.den))
                let gy = UInt16(Int64(metadata.display_primaries.1.1.num) * 50000 / Int64(metadata.display_primaries.1.1.den))
                let bx = UInt16(Int64(metadata.display_primaries.2.0.num) * 50000 / Int64(metadata.display_primaries.2.0.den))
                let by = UInt16(Int64(metadata.display_primaries.2.1.num) * 50000 / Int64(metadata.display_primaries.2.1.den))
                let wx = UInt16(Int64(metadata.white_point.0.num) * 50000 / Int64(metadata.white_point.0.den))
                let wy = UInt16(Int64(metadata.white_point.1.num) * 50000 / Int64(metadata.white_point.1.den))
                let maxLum = UInt32(Int64(metadata.max_luminance.num) * 10000 / Int64(metadata.max_luminance.den))
                let minLum = UInt32(Int64(metadata.min_luminance.num) * 10000 / Int64(metadata.min_luminance.den))

                masteringDisplayMetadata = MasteringDisplayMetadata(
                    displayPrimariesX: [rx, gx, bx],
                    displayPrimariesY: [ry, gy, by],
                    whitePointX: wx,
                    whitePointY: wy,
                    maxLuminance: maxLum,
                    minLuminance: minLum
                )

                print("📊 Found SMPTE ST 2086 metadata:")
                print("   Max Luminance: \(maxLum / 10000) cd/m²")
                print("   Min Luminance: \(minLum) / 10000 cd/m²")
            } else {
                print("   ⚠️  Mastering display metadata present but has_primaries=\(metadata.has_primaries), has_luminance=\(metadata.has_luminance)")
            }
        } else {
            print("   ℹ️  No SMPTE ST 2086 metadata in codecpar (may be in frame side data)")
        }

        return VideoInfo(
            width: Int(codecPar.width),
            height: Int(codecPar.height),
            codecID: codecPar.codec_id,
            colorTransfer: codecPar.color_trc,
            colorPrimaries: codecPar.color_primaries,
            extradata: extradata,
            pixelFormat: AVPixelFormat(codecPar.format),
            masteringDisplayMetadata: masteringDisplayMetadata
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

public struct MasteringDisplayMetadata {
    public let displayPrimariesX: [UInt16]  // 3 values (R, G, B) in 0.00002 increments
    public let displayPrimariesY: [UInt16]  // 3 values (R, G, B) in 0.00002 increments
    public let whitePointX: UInt16          // in 0.00002 increments
    public let whitePointY: UInt16          // in 0.00002 increments
    public let maxLuminance: UInt32         // in 0.0001 cd/m² increments
    public let minLuminance: UInt32         // in 0.0001 cd/m² increments
}

public struct VideoInfo {
    public let width: Int
    public let height: Int
    public let codecID: AVCodecID
    public let colorTransfer: AVColorTransferCharacteristic
    public let colorPrimaries: AVColorPrimaries
    public let extradata: Data?
    public let pixelFormat: AVPixelFormat
    public let masteringDisplayMetadata: MasteringDisplayMetadata?

    public var isHDR10: Bool {
        colorTransfer == AVCOL_TRC_SMPTE2084 && colorPrimaries == AVCOL_PRI_BT2020
    }

    public var isHLG: Bool {
        colorTransfer == AVCOL_TRC_ARIB_STD_B67
    }

    /// Human-readable codec name
    public var codecName: String {
        switch codecID {
        case AV_CODEC_ID_H264:
            return "H.264/AVC"
        case AV_CODEC_ID_HEVC:
            return "HEVC/H.265"
        case AV_CODEC_ID_VP9:
            return "VP9"
        case AV_CODEC_ID_AV1:
            return "AV1"
        case AV_CODEC_ID_MPEG4:
            return "MPEG-4"
        case AV_CODEC_ID_VP8:
            return "VP8"
        default:
            return "Codec \(codecID.rawValue)"
        }
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

