//
//  VideoDecoderTests.swift
//  hdrplay
//
//  Created by Andrew Sartor on 2025/11/18.
//

import XCTest
@testable import HDRPlay
import CFFmpeg

final class VideoDecoderTests: XCTestCase {

    // MARK: - Test File Setup

    private func getTestFileURL() -> URL? {
        let testPaths = ["/tmp/test.mkv", "~/Downloads/test.mkv", "./test.mkv"]

        for path in testPaths {
            let expandedPath = NSString(string: path).expandingTildeInPath
            let url = URL(fileURLWithPath: expandedPath)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    // MARK: - Codec Discovery Tests

    func testCodecAvailability() {
        // Test that common codecs are available
        let hevcCodec = avcodec_find_decoder(AV_CODEC_ID_HEVC)
        XCTAssertNotNil(hevcCodec, "HEVC codec should be available")

        let h264Codec = avcodec_find_decoder(AV_CODEC_ID_H264)
        XCTAssertNotNil(h264Codec, "H264 codec should be available")

        if let codec = hevcCodec {
            let name = String(cString: codec.pointee.name)
            print("✅ HEVC codec found: \(name)")
        }
    }

    // MARK: - VideoInfo Tests

    func testVideoInfoExtraction() throws {
        guard let testURL = getTestFileURL() else {
            throw XCTSkip("No test MKV file available. Place a test.mkv at /tmp/test.mkv")
        }

        let demuxer = try MKVDemuxer(url: testURL)

        guard let videoInfo = demuxer.videoInfo else {
            XCTFail("VideoInfo should not be nil")
            return
        }

        print("📊 Video Information:")
        print("  Resolution: \(videoInfo.width)x\(videoInfo.height)")
        print("  Codec ID: \(videoInfo.codecID.rawValue)")
        print("  Pixel Format: \(videoInfo.pixelFormat.rawValue)")
        print("  Color Transfer: \(videoInfo.colorTransfer.rawValue)")
        print("  Color Primaries: \(videoInfo.colorPrimaries.rawValue)")
        print("  HDR10: \(videoInfo.isHDR10)")
        print("  HLG: \(videoInfo.isHLG)")

        // Check extradata
        if let extradata = videoInfo.extradata {
            print("  Extradata: \(extradata.count) bytes")
            print("  Extradata hex (first 32 bytes): \(extradata.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " "))")
            XCTAssertGreaterThan(extradata.count, 0, "Extradata should not be empty")
        } else {
            print("  ⚠️  WARNING: No extradata found!")
        }

        XCTAssertGreaterThan(videoInfo.width, 0)
        XCTAssertGreaterThan(videoInfo.height, 0)
    }

    // MARK: - Decoder Initialization Tests

    func testDecoderInitialization() throws {
        guard let testURL = getTestFileURL() else {
            throw XCTSkip("No test MKV file available")
        }

        let demuxer = try MKVDemuxer(url: testURL)

        guard let videoInfo = demuxer.videoInfo,
              let timebase = demuxer.timebase else {
            XCTFail("VideoInfo and timebase should be available")
            return
        }

        print("🔧 Attempting to initialize decoder...")
        print("  Codec ID: \(videoInfo.codecID.rawValue)")
        print("  Timebase: \(timebase.num)/\(timebase.den)")

        do {
            let decoder = try VideoDecoder(videoInfo: videoInfo, timebase: timebase)
            print("✅ Decoder initialized successfully")
            XCTAssertNotNil(decoder)
        } catch DecoderError.codecNotFound {
            XCTFail("❌ Codec not found for codec ID: \(videoInfo.codecID.rawValue)")
        } catch DecoderError.cannotOpenCodec {
            print("❌ Cannot open codec")
            print("   This is the error we're debugging!")
            print("   Extradata present: \(videoInfo.extradata != nil)")
            print("   Extradata size: \(videoInfo.extradata?.count ?? 0)")
            print("   Pixel format: \(videoInfo.pixelFormat.rawValue)")
            throw DecoderError.cannotOpenCodec
        } catch DecoderError.cannotAllocateContext {
            XCTFail("❌ Cannot allocate context")
        } catch DecoderError.cannotAllocateFrame {
            XCTFail("❌ Cannot allocate frame")
        } catch {
            XCTFail("❌ Unexpected error: \(error)")
        }
    }

    func testDecoderWithManualCodecContext() throws {
        guard let testURL = getTestFileURL() else {
            throw XCTSkip("No test MKV file available")
        }

        let demuxer = try MKVDemuxer(url: testURL)

        guard let videoInfo = demuxer.videoInfo else {
            XCTFail("VideoInfo should be available")
            return
        }

        // Try to manually create codec context with detailed error reporting
        print("🔍 Manual codec context creation test:")

        guard let codec = avcodec_find_decoder(videoInfo.codecID) else {
            XCTFail("Codec not found")
            return
        }
        print("  ✓ Codec found: \(String(cString: codec.pointee.name))")

        guard let context = avcodec_alloc_context3(codec) else {
            XCTFail("Cannot allocate context")
            return
        }
        defer {
            var ctx: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&ctx)
        }
        print("  ✓ Context allocated")

        // Set parameters
        context.pointee.width = Int32(videoInfo.width)
        context.pointee.height = Int32(videoInfo.height)
        context.pointee.pix_fmt = videoInfo.pixelFormat
        context.pointee.color_trc = videoInfo.colorTransfer
        context.pointee.color_primaries = videoInfo.colorPrimaries
        print("  ✓ Basic parameters set")

        // Copy extradata
        if let extradata = videoInfo.extradata, !extradata.isEmpty {
            context.pointee.extradata_size = Int32(extradata.count)
            context.pointee.extradata = av_malloc(extradata.count)?.assumingMemoryBound(to: UInt8.self)
            _ = extradata.withUnsafeBytes { bytes in
                memcpy(context.pointee.extradata, bytes.baseAddress, extradata.count)
            }
            print("  ✓ Extradata copied: \(extradata.count) bytes")
        } else {
            print("  ⚠️  No extradata to copy")
        }

        // Try to open codec
        print("  🔓 Attempting to open codec...")
        let result = avcodec_open2(context, codec, nil)

        if result == 0 {
            print("  ✅ SUCCESS! Codec opened successfully")
        } else {
            print("  ❌ FAILED! Error code: \(result)")

            // Get error string
            let bufferSize = 1024
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            av_strerror(result, buffer, bufferSize)
            let errorString = String(cString: buffer)
            print("  Error message: \(errorString)")

            XCTFail("avcodec_open2 failed with error: \(result) - \(errorString)")
        }
    }

    // MARK: - Decoding Tests

    func testDecodeFirstFrame() throws {
        guard let testURL = getTestFileURL() else {
            throw XCTSkip("No test MKV file available")
        }

        let demuxer = try MKVDemuxer(url: testURL)

        guard let videoInfo = demuxer.videoInfo,
              let timebase = demuxer.timebase else {
            XCTFail("VideoInfo and timebase should be available")
            return
        }

        let decoder = try VideoDecoder(videoInfo: videoInfo, timebase: timebase)

        print("🎬 Attempting to decode first frame...")

        var frameDecoded = false
        var packetCount = 0
        let maxPackets = 50  // Try up to 50 packets

        while let packet = try demuxer.readPacket(), packetCount < maxPackets {
            packetCount += 1

            let frames = try decoder.decode(packet: packet)

            if !frames.isEmpty {
                print("✅ Decoded \(frames.count) frame(s) from packet \(packetCount)")

                let frame = frames[0]
                print("  Frame info:")
                print("    PTS: \(frame.pts)")
                print("    Duration: \(frame.duration)")
                print("    Is Keyframe: \(frame.isKeyFrame)")

                // Verify pixel buffer
                let width = CVPixelBufferGetWidth(frame.pixelBuffer)
                let height = CVPixelBufferGetHeight(frame.pixelBuffer)
                let pixelFormat = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)

                print("    PixelBuffer: \(width)x\(height), format: \(pixelFormat)")

                XCTAssertGreaterThan(width, 0)
                XCTAssertGreaterThan(height, 0)

                frameDecoded = true
                break
            }
        }

        print("Processed \(packetCount) packets")
        XCTAssertTrue(frameDecoded, "Should decode at least one frame")
    }

    func testDecodeMultipleFrames() throws {
        guard let testURL = getTestFileURL() else {
            throw XCTSkip("No test MKV file available")
        }

        let demuxer = try MKVDemuxer(url: testURL)

        guard let videoInfo = demuxer.videoInfo,
              let timebase = demuxer.timebase else {
            XCTFail("VideoInfo and timebase should be available")
            return
        }

        let decoder = try VideoDecoder(videoInfo: videoInfo, timebase: timebase)

        var totalFrames = 0
        var packetCount = 0
        let maxPackets = 100

        while let packet = try demuxer.readPacket(), packetCount < maxPackets {
            packetCount += 1
            let frames = try decoder.decode(packet: packet)
            totalFrames += frames.count
        }

        print("📊 Decoded \(totalFrames) frames from \(packetCount) packets")
        XCTAssertGreaterThan(totalFrames, 0, "Should decode at least one frame")
    }

    // MARK: - Error Handling Tests

    func testDecoderWithInvalidVideoInfo() {
        // Create invalid VideoInfo
        let invalidInfo = VideoInfo(
            width: 0,
            height: 0,
            codecID: AV_CODEC_ID_NONE,
            colorTransfer: AVCOL_TRC_UNSPECIFIED,
            colorPrimaries: AVCOL_PRI_UNSPECIFIED,
            extradata: nil,
            pixelFormat: AV_PIX_FMT_NONE,
            masteringDisplayMetadata: nil
        )

        let timebase = AVRational(num: 1, den: 1000000)

        XCTAssertThrowsError(try VideoDecoder(videoInfo: invalidInfo, timebase: timebase)) { error in
            print("Expected error for invalid codec: \(error)")
        }
    }

    // MARK: - VideoToolbox Decoder Tests

    func testVideoToolboxDecoderInitialization() throws {
        guard let testURL = getTestFileURL() else {
            throw XCTSkip("No test MKV file available")
        }

        let demuxer = try MKVDemuxer(url: testURL)

        guard let videoInfo = demuxer.videoInfo,
              let timebase = demuxer.timebase else {
            XCTFail("VideoInfo and timebase should be available")
            return
        }

        print("🔧 Attempting to initialize VideoToolbox decoder...")
        let decoder = try VideoToolboxDecoder(videoInfo: videoInfo, timebase: timebase)
        print("✅ VideoToolbox decoder initialized successfully")
        XCTAssertNotNil(decoder)
    }

    func testVideoToolboxDecodeFirstFrame() throws {
        guard let testURL = getTestFileURL() else {
            throw XCTSkip("No test MKV file available")
        }

        let demuxer = try MKVDemuxer(url: testURL)

        guard let videoInfo = demuxer.videoInfo,
              let timebase = demuxer.timebase else {
            XCTFail("VideoInfo and timebase should be available")
            return
        }

        let decoder = try VideoToolboxDecoder(videoInfo: videoInfo, timebase: timebase)

        print("🎬 Attempting to decode first frame with VideoToolbox...")

        var frameDecoded = false
        var packetCount = 0
        let maxPackets = 50

        while let packet = try demuxer.readPacket(), packetCount < maxPackets {
            packetCount += 1

            let frames = try decoder.decode(packet: packet)

            if !frames.isEmpty {
                print("✅ Decoded \(frames.count) frame(s) from packet \(packetCount)")

                let frame = frames[0]
                print("  Frame info:")
                print("    PTS: \(frame.pts)")
                print("    Duration: \(frame.duration)")
                print("    Is Keyframe: \(frame.isKeyFrame)")

                // Verify pixel buffer
                let width = CVPixelBufferGetWidth(frame.pixelBuffer)
                let height = CVPixelBufferGetHeight(frame.pixelBuffer)
                let pixelFormat = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)

                print("    PixelBuffer: \(width)x\(height), format: \(pixelFormat)")

                XCTAssertGreaterThan(width, 0)
                XCTAssertGreaterThan(height, 0)

                frameDecoded = true
                break
            }
        }

        print("Processed \(packetCount) packets")
        XCTAssertTrue(frameDecoded, "Should decode at least one frame")
    }

    func testVideoToolboxDecodeMultipleFrames() throws {
        guard let testURL = getTestFileURL() else {
            throw XCTSkip("No test MKV file available")
        }

        let demuxer = try MKVDemuxer(url: testURL)

        guard let videoInfo = demuxer.videoInfo,
              let timebase = demuxer.timebase else {
            XCTFail("VideoInfo and timebase should be available")
            return
        }

        let decoder = try VideoToolboxDecoder(videoInfo: videoInfo, timebase: timebase)

        var totalFrames = 0
        var packetCount = 0
        let maxPackets = 100

        while let packet = try demuxer.readPacket(), packetCount < maxPackets {
            packetCount += 1
            let frames = try decoder.decode(packet: packet)
            totalFrames += frames.count
        }

        print("📊 VideoToolbox decoded \(totalFrames) frames from \(packetCount) packets")
        XCTAssertGreaterThan(totalFrames, 0, "Should decode at least one frame")
    }

    // MARK: - Performance Tests

    func testDecodingPerformance() throws {
        guard let testURL = getTestFileURL() else {
            throw XCTSkip("No test MKV file available")
        }

        measure {
            do {
                let demuxer = try MKVDemuxer(url: testURL)

                guard let videoInfo = demuxer.videoInfo,
                      let timebase = demuxer.timebase else {
                    return
                }

                let decoder = try VideoDecoder(videoInfo: videoInfo, timebase: timebase)

                var frameCount = 0
                var packetCount = 0

                while let packet = try demuxer.readPacket(), packetCount < 100 {
                    let frames = try decoder.decode(packet: packet)
                    frameCount += frames.count
                    packetCount += 1
                }

                print("Performance test: \(frameCount) frames from \(packetCount) packets")
            } catch {
                XCTFail("Performance test failed: \(error)")
            }
        }
    }
}
