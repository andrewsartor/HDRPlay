//
//  VideoDecoder.swift
//  HDRPlay
//
//  Created by Andrew Sartor on 2025/11/18.
//

import AVFoundation
import CFFmpeg
import Foundation

public enum DecoderError: Error {
    case codecNotFound
    case cannotOpenCodec
    case cannotAllocateContext
    case cannotAllocateFrame
    case decodingFailed(code: Int32)
}

public struct DecodedFrame {
    public let pixelBuffer: CVPixelBuffer
    public let pts: Int64
    public let duration: Int64
    public let isKeyFrame: Bool
}

public class VideoDecoder {
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var timebase: AVRational
    private var videoInfo: VideoInfo

    public init(videoInfo: VideoInfo, timebase: AVRational) throws {
        self.timebase = timebase
        self.videoInfo = videoInfo

        guard let codec = avcodec_find_decoder(videoInfo.codecID) else {
            throw DecoderError.codecNotFound
        }

        guard let context = avcodec_alloc_context3(codec) else {
            throw DecoderError.cannotAllocateContext
        }

        self.codecContext = context

        // Context parameter setup
        context.pointee.width = Int32(videoInfo.width)
        context.pointee.height = Int32(videoInfo.height)
        context.pointee.color_trc = videoInfo.colorTransfer
        context.pointee.color_primaries = videoInfo.colorPrimaries
        context.pointee.pix_fmt = videoInfo.pixelFormat

        // Copy extradata (critical for HEVC/H.264)
        if let extradata = videoInfo.extradata, !extradata.isEmpty {
            context.pointee.extradata_size = Int32(extradata.count)
            context.pointee.extradata = av_malloc(extradata.count)?.assumingMemoryBound(to: UInt8.self)
            _ = extradata.withUnsafeBytes { bytes in
                memcpy(context.pointee.extradata, bytes.baseAddress, extradata.count)
            }
        }

        guard avcodec_open2(context, codec, nil) == 0 else {
            throw DecoderError.cannotOpenCodec
        }

        guard let frame = av_frame_alloc() else {
            throw DecoderError.cannotAllocateFrame
        }

        self.frame = frame

        print("✅ Decoder initialized: \(videoInfo.width)x\(videoInfo.height)")
    }

    public func decode(packet: VideoPacket) throws -> [DecodedFrame] {
        guard let codecContext = codecContext,
            let frame = frame
        else {
            throw DecoderError.cannotAllocateContext
        }

        var frames: [DecodedFrame] = []

        guard let avPacket = av_packet_alloc() else {
            throw DecoderError.decodingFailed(code: -1)
        }
        defer {
            var packet: UnsafeMutablePointer<AVPacket>? = avPacket
            av_packet_free(&packet)
        }

        packet.data.withUnsafeBytes { buffer in
            avPacket.pointee.data = UnsafeMutablePointer(
                mutating: buffer.baseAddress?.assumingMemoryBound(to: UInt8.self))
            avPacket.pointee.size = Int32(packet.data.count)
            avPacket.pointee.pts = packet.pts
            avPacket.pointee.dts = packet.dts
            avPacket.pointee.duration = packet.duration
        }

        let sendResult = avcodec_send_packet(codecContext, avPacket)
        guard sendResult == 0 else {
            throw DecoderError.decodingFailed(code: sendResult)
        }

        // Receive
        while true {
            let receiveResult = avcodec_receive_frame(codecContext, frame)

            if receiveResult == get_averror_eagain() || receiveResult == get_averror_eof() {
                break
            }

            guard receiveResult == 0 else {
                throw DecoderError.decodingFailed(code: receiveResult)
            }

            if let pixelBuffer = try convertFrameToPixelBuffer(frame: frame) {
                let decodedFrame = DecodedFrame(
                    pixelBuffer: pixelBuffer, pts: frame.pointee.pkt_dts,
                    duration: frame.pointee.duration,
                    isKeyFrame: (frame.pointee.flags & AV_FRAME_FLAG_KEY) != 0)
                frames.append(decodedFrame)
            }

            av_frame_unref(frame)
        }

        return frames
    }

    private func convertFrameToPixelBuffer(frame: UnsafeMutablePointer<AVFrame>) throws
        -> CVPixelBuffer?
    {
        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)

        // Determine pixel format based on bit depth
        let pixelFormat: OSType
        let is10Bit = frame.pointee.format == AV_PIX_FMT_YUV420P10LE.rawValue ||
                      frame.pointee.format == AV_PIX_FMT_YUV420P10BE.rawValue

        if is10Bit {
            // HDR content - use 10-bit format
            pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            print("🎨 Using 10-bit pixel format for HDR")
        } else {
            // SDR content - use 8-bit format
            pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            print("🎨 Using 8-bit pixel format for SDR")
        }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, pixelFormat,
            [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
                as CFDictionary, &pixelBuffer)

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        // Check for frame-level mastering display metadata (common in MKV files)
        checkFrameSideData(frame: frame)

        // Attach HDR color space information
        attachColorSpaceInfo(to: buffer)

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        // Copy Y plane
        guard let yPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
            return nil
        }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard let yData = frame.pointee.data.0 else {
            return nil
        }
        let yLineSize = Int(frame.pointee.linesize.0)
        let bytesPerPixel = is10Bit ? 2 : 1

        for row in 0..<height {
            let srcPtr = yData.advanced(by: row * yLineSize)
            let dstPtr = yPlane.advanced(by: row * yStride)
            memcpy(dstPtr, srcPtr, width * bytesPerPixel)
        }

        // Copy UV plane (interleaved)
        guard let uvPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
            return nil
        }
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        guard let uData = frame.pointee.data.1,
            let vData = frame.pointee.data.2
        else {
            return nil
        }
        let uvLineSize = Int(frame.pointee.linesize.1)

        if is10Bit {
            // 10-bit: interleave U and V (UInt16 values)
            for row in 0..<(height / 2) {
                let dstPtr = uvPlane.advanced(by: row * uvStride).assumingMemoryBound(to: UInt16.self)

                // Reinterpret UInt8 pointers as UInt16 for 10-bit data
                let uSrcPtr = uData.advanced(by: row * uvLineSize)
                let vSrcPtr = vData.advanced(by: row * uvLineSize)

                uSrcPtr.withMemoryRebound(to: UInt16.self, capacity: width / 2) { uPtr in
                    vSrcPtr.withMemoryRebound(to: UInt16.self, capacity: width / 2) { vPtr in
                        for col in 0..<(width / 2) {
                            dstPtr[col * 2] = uPtr[col]
                            dstPtr[col * 2 + 1] = vPtr[col]
                        }
                    }
                }
            }
        } else {
            // 8-bit: interleave U and V (UInt8 values)
            for row in 0..<(height / 2) {
                let dstPtr = uvPlane.advanced(by: row * uvStride).assumingMemoryBound(to: UInt8.self)
                let uPtr = uData.advanced(by: row * uvLineSize)
                let vPtr = vData.advanced(by: row * uvLineSize)

                for col in 0..<(width / 2) {
                    dstPtr[col * 2] = uPtr[col]
                    dstPtr[col * 2 + 1] = vPtr[col]
                }
            }
        }

        return buffer
    }

    private var hasLoggedFrameMetadata = false

    private func checkFrameSideData(frame: UnsafeMutablePointer<AVFrame>) {
        // Only log once to avoid spam
        guard !hasLoggedFrameMetadata else { return }

        let sideDataPtr = av_frame_get_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA)
        if let sideData = sideDataPtr {
            hasLoggedFrameMetadata = true

            let metadata = sideData.pointee.data.withMemoryRebound(
                to: AVMasteringDisplayMetadata.self,
                capacity: 1
            ) { ptr in
                return ptr.pointee
            }

            if metadata.has_primaries != 0 || metadata.has_luminance != 0 {
                // Use Int64 for intermediate calculations to avoid overflow
                let maxLum = UInt32(Int64(metadata.max_luminance.num) * 10000 / Int64(metadata.max_luminance.den))
                let minLum = UInt32(Int64(metadata.min_luminance.num) * 10000 / Int64(metadata.min_luminance.den))

                print("📊 Found SMPTE ST 2086 metadata in frame side data:")
                print("   Max Luminance: \(maxLum / 10000) cd/m²")
                print("   Min Luminance: \(minLum) / 10000 cd/m²")

                // Store in videoInfo for future frames
                let rx = UInt16(Int64(metadata.display_primaries.0.0.num) * 50000 / Int64(metadata.display_primaries.0.0.den))
                let ry = UInt16(Int64(metadata.display_primaries.0.1.num) * 50000 / Int64(metadata.display_primaries.0.1.den))
                let gx = UInt16(Int64(metadata.display_primaries.1.0.num) * 50000 / Int64(metadata.display_primaries.1.0.den))
                let gy = UInt16(Int64(metadata.display_primaries.1.1.num) * 50000 / Int64(metadata.display_primaries.1.1.den))
                let bx = UInt16(Int64(metadata.display_primaries.2.0.num) * 50000 / Int64(metadata.display_primaries.2.0.den))
                let by = UInt16(Int64(metadata.display_primaries.2.1.num) * 50000 / Int64(metadata.display_primaries.2.1.den))
                let wx = UInt16(Int64(metadata.white_point.0.num) * 50000 / Int64(metadata.white_point.0.den))
                let wy = UInt16(Int64(metadata.white_point.1.num) * 50000 / Int64(metadata.white_point.1.den))

                // Update videoInfo with frame metadata
                let frameMasteringMetadata = MasteringDisplayMetadata(
                    displayPrimariesX: [rx, gx, bx],
                    displayPrimariesY: [ry, gy, by],
                    whitePointX: wx,
                    whitePointY: wy,
                    maxLuminance: maxLum,
                    minLuminance: minLum
                )

                // Create updated VideoInfo with the mastering metadata
                var updatedInfo = videoInfo
                updatedInfo = VideoInfo(
                    width: updatedInfo.width,
                    height: updatedInfo.height,
                    codecID: updatedInfo.codecID,
                    colorTransfer: updatedInfo.colorTransfer,
                    colorPrimaries: updatedInfo.colorPrimaries,
                    extradata: updatedInfo.extradata,
                    pixelFormat: updatedInfo.pixelFormat,
                    masteringDisplayMetadata: frameMasteringMetadata
                )
                videoInfo = updatedInfo
            }
        }
    }

    private func attachColorSpaceInfo(to pixelBuffer: CVPixelBuffer) {
        // Attach color primaries
        let colorPrimaries: CFString
        switch videoInfo.colorPrimaries {
        case AVCOL_PRI_BT2020:
            colorPrimaries = kCVImageBufferColorPrimaries_ITU_R_2020 as CFString
        case AVCOL_PRI_BT709:
            colorPrimaries = kCVImageBufferColorPrimaries_ITU_R_709_2 as CFString
        default:
            colorPrimaries = kCVImageBufferColorPrimaries_ITU_R_709_2 as CFString
        }
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, colorPrimaries, .shouldPropagate)

        // Attach transfer function
        let transferFunction: CFString
        switch videoInfo.colorTransfer {
        case AVCOL_TRC_SMPTE2084:  // HDR10 (PQ)
            transferFunction = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as CFString
        case AVCOL_TRC_ARIB_STD_B67:  // HLG
            transferFunction = kCVImageBufferTransferFunction_ITU_R_2100_HLG as CFString
        case AVCOL_TRC_BT709:
            transferFunction = kCVImageBufferTransferFunction_ITU_R_709_2 as CFString
        default:
            transferFunction = kCVImageBufferTransferFunction_ITU_R_709_2 as CFString
        }
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, transferFunction, .shouldPropagate)

        // Attach YCbCr matrix
        let yCbCrMatrix: CFString
        switch videoInfo.colorPrimaries {
        case AVCOL_PRI_BT2020:
            yCbCrMatrix = kCVImageBufferYCbCrMatrix_ITU_R_2020 as CFString
        case AVCOL_PRI_BT709:
            yCbCrMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2 as CFString
        default:
            yCbCrMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2 as CFString
        }
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, yCbCrMatrix, .shouldPropagate)

        // Attach SMPTE ST 2086 mastering display metadata if available
        if let masteringMetadata = videoInfo.masteringDisplayMetadata {
            attachMasteringDisplayMetadata(masteringMetadata, to: pixelBuffer)
        }

        // Debug logging
        if videoInfo.isHDR10 {
            print("🎨 Attached HDR10 color space: BT.2020 + PQ")
        } else if videoInfo.isHLG {
            print("🎨 Attached HLG color space: BT.2020 + HLG")
        } else {
            print("🎨 Attached SDR color space: BT.709")
        }
    }

    private func attachMasteringDisplayMetadata(_ metadata: MasteringDisplayMetadata, to pixelBuffer: CVPixelBuffer) {
        // Create CFData with mastering display color volume
        // Format: array of 10 CFNumbers representing chromaticity coordinates and luminance
        let dict: [CFString: Any] = [
            "RedX" as CFString: metadata.displayPrimariesX[0],
            "RedY" as CFString: metadata.displayPrimariesY[0],
            "GreenX" as CFString: metadata.displayPrimariesX[1],
            "GreenY" as CFString: metadata.displayPrimariesY[1],
            "BlueX" as CFString: metadata.displayPrimariesX[2],
            "BlueY" as CFString: metadata.displayPrimariesY[2],
            "WhitePointX" as CFString: metadata.whitePointX,
            "WhitePointY" as CFString: metadata.whitePointY,
            "MaxLuminance" as CFString: metadata.maxLuminance,
            "MinLuminance" as CFString: metadata.minLuminance
        ]

        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferMasteringDisplayColorVolumeKey,
            dict as CFDictionary,
            .shouldPropagate
        )

        print("📊 Attached SMPTE ST 2086 metadata to pixel buffer")
    }

    public func flush() throws -> [DecodedFrame] {
        guard let codecContext = codecContext else {
            throw DecoderError.cannotAllocateContext
        }

        var frames: [DecodedFrame] = []

        // Null packet to flush
        avcodec_send_packet(codecContext, nil)

        while let frame = frame {
            let receiveResult = avcodec_receive_frame(codecContext, frame)

            if receiveResult == get_averror_eagain() || receiveResult == get_averror_eof() {
                break
            }

            guard receiveResult == 0 else {
                throw DecoderError.decodingFailed(code: receiveResult)
            }

            if let pixelBuffer = try convertFrameToPixelBuffer(frame: frame) {
                let decodedFrame = DecodedFrame(
                    pixelBuffer: pixelBuffer, pts: frame.pointee.pts,
                    duration: frame.pointee.duration,
                    isKeyFrame: (frame.pointee.flags & AV_FRAME_FLAG_KEY) != 0)
                frames.append(decodedFrame)
            }

            av_frame_unref(frame)
        }

        return frames
    }

    deinit {
        av_frame_free(&self.frame)
        avcodec_free_context(&self.codecContext)
    }
}
