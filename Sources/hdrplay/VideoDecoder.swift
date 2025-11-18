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

    public init(videoInfo: VideoInfo, timebase: AVRational) throws {
        self.timebase = timebase

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

        var pixelBuffer: CVPixelBuffer?
        let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, pixelFormat,
            [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
                as CFDictionary, &pixelBuffer)

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let yPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
            return nil
        }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard let yData = frame.pointee.data.0 else {
            return nil
        }
        let yLineSize = Int(frame.pointee.linesize.0)

        for row in 0..<height {
            let srcPtr = yData.advanced(by: row * yLineSize)
            let dstPtr = yPlane.advanced(by: row * yStride)
            memcpy(dstPtr, srcPtr, width)
        }

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

        for row in 0..<(height / 2) {
            let dstPtr = uvPlane.advanced(by: row * uvStride).assumingMemoryBound(to: UInt8.self)
            let uPtr = uData.advanced(by: row * uvLineSize)
            let vPtr = vData.advanced(by: row * uvLineSize)

            for col in 0..<(width / 2) {
                dstPtr[col * 2] = uPtr[col]
                dstPtr[col * 2 + 1] = vPtr[col]
            }
        }

        return buffer
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
