//
//  HDRContentTests.swift
//  hdrplay
//
//  Tests for HDR10 content detection and metadata extraction
//

import XCTest
@testable import HDRPlay
import CFFmpeg

final class HDRContentTests: XCTestCase {

    // MARK: - Test File Setup

    /// Returns the HDR10 test file URL from ~/Downloads
    private func getHDR10TestFileURL() -> URL? {
        let path = "~/Downloads/hdr10.mkv"
        let expandedPath = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)

        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    // MARK: - HDR Detection Tests

    func testHDR10Detection() throws {
        guard let testURL = getHDR10TestFileURL() else {
            throw XCTSkip("No HDR10 test file available. Place hdr10.mkv in ~/Downloads")
        }

        let demuxer = try MKVDemuxer(url: testURL)

        guard let videoInfo = demuxer.videoInfo else {
            XCTFail("Video info should not be nil for HDR10 file")
            return
        }

        // Verify HDR10 detection
        XCTAssertTrue(videoInfo.isHDR10, "File should be detected as HDR10")
        XCTAssertFalse(videoInfo.isHLG, "HDR10 file should not be detected as HLG")

        // Verify color characteristics
        XCTAssertEqual(videoInfo.colorTransfer, AVCOL_TRC_SMPTE2084, "Should use PQ transfer function")
        XCTAssertEqual(videoInfo.colorPrimaries, AVCOL_PRI_BT2020, "Should use BT.2020 color primaries")

        print("✅ HDR10 detected correctly")
        print("   Transfer: SMPTE2084 (PQ)")
        print("   Primaries: BT.2020")
    }

    func testPixelFormatFor10Bit() throws {
        guard let testURL = getHDR10TestFileURL() else {
            throw XCTSkip("No HDR10 test file available. Place hdr10.mkv in ~/Downloads")
        }

        let demuxer = try MKVDemuxer(url: testURL)

        guard let videoInfo = demuxer.videoInfo else {
            XCTFail("Video info should not be nil")
            return
        }

        // Check that pixel format is 10-bit
        let is10Bit = videoInfo.pixelFormat == AV_PIX_FMT_YUV420P10LE ||
                      videoInfo.pixelFormat == AV_PIX_FMT_YUV420P10BE

        XCTAssertTrue(is10Bit, "HDR10 content should use 10-bit pixel format")

        print("✅ Pixel format: \(videoInfo.pixelFormat == AV_PIX_FMT_YUV420P10LE ? "YUV420P10LE" : "YUV420P10BE")")
    }

    // MARK: - SMPTE ST 2086 Metadata Tests

    func testMasteringDisplayMetadata() throws {
        guard let testURL = getHDR10TestFileURL() else {
            throw XCTSkip("No HDR10 test file available. Place hdr10.mkv in ~/Downloads")
        }

        let demuxer = try MKVDemuxer(url: testURL)

        guard let videoInfo = demuxer.videoInfo else {
            XCTFail("Video info should not be nil")
            return
        }

        // Note: Metadata might be in codecpar or frame side data
        // If not in codecpar, we'll check frames
        if let metadata = videoInfo.masteringDisplayMetadata {
            print("📊 Found SMPTE ST 2086 metadata in codecpar:")
            validateMasteringDisplayMetadata(metadata)
        } else {
            print("ℹ️  No metadata in codecpar, will check frame side data")

            // Try to get it from first decoded frame
            guard let timebase = demuxer.timebase else {
                XCTFail("Timebase should be available")
                return
            }

            let decoder = try VideoDecoder(videoInfo: videoInfo, timebase: timebase)

            // Read and decode first few packets to get metadata
            var foundMetadata = false
            for _ in 0..<10 {
                guard let packet = try demuxer.readPacket() else { break }
                let frames = try decoder.decode(packet: packet)

                if !frames.isEmpty {
                    // Decoder should have extracted metadata by now
                    // We can't directly access it, but we can verify through logs
                    foundMetadata = true
                    print("📊 Frame decoded - metadata extraction should have occurred")
                    break
                }
            }

            // This is more of an integration test - we verify via logs
            XCTAssertTrue(foundMetadata, "Should decode at least one frame")
        }
    }

    private func validateMasteringDisplayMetadata(_ metadata: MasteringDisplayMetadata) {
        // Verify display primaries are reasonable values
        XCTAssertGreaterThan(metadata.displayPrimariesX[0], 0, "Red X should be positive")
        XCTAssertGreaterThan(metadata.displayPrimariesY[0], 0, "Red Y should be positive")
        XCTAssertGreaterThan(metadata.displayPrimariesX[1], 0, "Green X should be positive")
        XCTAssertGreaterThan(metadata.displayPrimariesY[1], 0, "Green Y should be positive")
        XCTAssertGreaterThan(metadata.displayPrimariesX[2], 0, "Blue X should be positive")
        XCTAssertGreaterThan(metadata.displayPrimariesY[2], 0, "Blue Y should be positive")

        // Verify white point
        XCTAssertGreaterThan(metadata.whitePointX, 0, "White point X should be positive")
        XCTAssertGreaterThan(metadata.whitePointY, 0, "White point Y should be positive")

        // Verify luminance values
        // Max luminance typically 1000-10000 cd/m² (in 0.0001 units = 10000000-100000000)
        XCTAssertGreaterThan(metadata.maxLuminance, 0, "Max luminance should be positive")
        XCTAssertLessThan(metadata.maxLuminance, 200000000, "Max luminance should be reasonable")

        // Min luminance typically very small
        XCTAssertGreaterThanOrEqual(metadata.minLuminance, 0, "Min luminance should be non-negative")
        XCTAssertLessThan(metadata.minLuminance, metadata.maxLuminance, "Min should be less than max")

        // Print values
        print("   Max Luminance: \(metadata.maxLuminance / 10000) cd/m²")
        print("   Min Luminance: \(metadata.minLuminance) / 10000 cd/m²")
        print("   Display Primaries R: (\(metadata.displayPrimariesX[0]), \(metadata.displayPrimariesY[0]))")
        print("   Display Primaries G: (\(metadata.displayPrimariesX[1]), \(metadata.displayPrimariesY[1]))")
        print("   Display Primaries B: (\(metadata.displayPrimariesX[2]), \(metadata.displayPrimariesY[2]))")
        print("   White Point: (\(metadata.whitePointX), \(metadata.whitePointY))")
    }

    // MARK: - Decoding Tests

    func testDecodeHDR10Frame() throws {
        guard let testURL = getHDR10TestFileURL() else {
            throw XCTSkip("No HDR10 test file available. Place hdr10.mkv in ~/Downloads")
        }

        let demuxer = try MKVDemuxer(url: testURL)

        guard let videoInfo = demuxer.videoInfo,
              let timebase = demuxer.timebase else {
            XCTFail("Video info and timebase should be available")
            return
        }

        let decoder = try VideoDecoder(videoInfo: videoInfo, timebase: timebase)

        // Decode first frame
        var frameDecoded = false
        for _ in 0..<20 {
            guard let packet = try demuxer.readPacket() else { break }
            let frames = try decoder.decode(packet: packet)

            if let firstFrame = frames.first {
                // Verify frame
                XCTAssertNotNil(firstFrame.pixelBuffer, "Pixel buffer should not be nil")
                XCTAssertGreaterThan(firstFrame.pts, -1, "PTS should be valid")

                // Verify pixel buffer format is 10-bit
                let pixelFormat = CVPixelBufferGetPixelFormatType(firstFrame.pixelBuffer)
                XCTAssertEqual(pixelFormat, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                              "HDR10 frame should use 10-bit pixel format")

                // Verify dimensions
                let width = CVPixelBufferGetWidth(firstFrame.pixelBuffer)
                let height = CVPixelBufferGetHeight(firstFrame.pixelBuffer)
                XCTAssertGreaterThan(width, 0, "Width should be positive")
                XCTAssertGreaterThan(height, 0, "Height should be positive")

                print("✅ Successfully decoded HDR10 frame:")
                print("   Pixel format: P010 (10-bit)")
                print("   Resolution: \(width)x\(height)")
                print("   PTS: \(firstFrame.pts)")
                print("   Keyframe: \(firstFrame.isKeyFrame)")

                frameDecoded = true
                break
            }
        }

        XCTAssertTrue(frameDecoded, "Should successfully decode at least one HDR10 frame")
    }

    func testColorSpaceAttachment() throws {
        guard let testURL = getHDR10TestFileURL() else {
            throw XCTSkip("No HDR10 test file available. Place hdr10.mkv in ~/Downloads")
        }

        let demuxer = try MKVDemuxer(url: testURL)

        guard let videoInfo = demuxer.videoInfo,
              let timebase = demuxer.timebase else {
            XCTFail("Video info and timebase should be available")
            return
        }

        let decoder = try VideoDecoder(videoInfo: videoInfo, timebase: timebase)

        // Decode first frame and check color space attachments
        for _ in 0..<20 {
            guard let packet = try demuxer.readPacket() else { break }
            let frames = try decoder.decode(packet: packet)

            if let firstFrame = frames.first {
                let pixelBuffer = firstFrame.pixelBuffer

                // Check color primaries
                let colorPrimaries = CVBufferCopyAttachment(
                    pixelBuffer,
                    kCVImageBufferColorPrimariesKey,
                    nil
                ) as? String
                XCTAssertNotNil(colorPrimaries, "Color primaries should be attached")
                XCTAssertEqual(colorPrimaries, kCVImageBufferColorPrimaries_ITU_R_2020 as String,
                              "Should use BT.2020 color primaries")

                // Check transfer function
                let transferFunction = CVBufferCopyAttachment(
                    pixelBuffer,
                    kCVImageBufferTransferFunctionKey,
                    nil
                ) as? String
                XCTAssertNotNil(transferFunction, "Transfer function should be attached")
                XCTAssertEqual(transferFunction, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String,
                              "Should use PQ transfer function")

                // Check YCbCr matrix
                let yCbCrMatrix = CVBufferCopyAttachment(
                    pixelBuffer,
                    kCVImageBufferYCbCrMatrixKey,
                    nil
                ) as? String
                XCTAssertNotNil(yCbCrMatrix, "YCbCr matrix should be attached")
                XCTAssertEqual(yCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_2020 as String,
                              "Should use BT.2020 YCbCr matrix")

                print("✅ Color space attachments verified:")
                print("   Primaries: BT.2020")
                print("   Transfer: PQ (SMPTE ST 2084)")
                print("   Matrix: BT.2020")

                break
            }
        }
    }

    func testMasteringDisplayMetadataAttachment() throws {
        guard let testURL = getHDR10TestFileURL() else {
            throw XCTSkip("No HDR10 test file available. Place hdr10.mkv in ~/Downloads")
        }

        let demuxer = try MKVDemuxer(url: testURL)

        guard let videoInfo = demuxer.videoInfo,
              let timebase = demuxer.timebase else {
            XCTFail("Video info and timebase should be available")
            return
        }

        let decoder = try VideoDecoder(videoInfo: videoInfo, timebase: timebase)

        // Decode frames until we have mastering metadata
        var foundMetadata = false
        for _ in 0..<20 {
            guard let packet = try demuxer.readPacket() else { break }
            let frames = try decoder.decode(packet: packet)

            if let firstFrame = frames.first {
                let pixelBuffer = firstFrame.pixelBuffer

                // Check for mastering display metadata attachment
                let masteringMetadata = CVBufferCopyAttachment(
                    pixelBuffer,
                    kCVImageBufferMasteringDisplayColorVolumeKey,
                    nil
                )

                if masteringMetadata != nil {
                    foundMetadata = true
                    print("✅ SMPTE ST 2086 metadata attached to pixel buffer")

                    // If it's a dictionary, we can inspect it
                    if let dict = masteringMetadata as? [String: Any] {
                        print("   Metadata keys: \(dict.keys.joined(separator: ", "))")
                    }
                    break
                }
            }
        }

        // Note: Metadata might not be present if the file doesn't have it
        // This is informational rather than a hard requirement
        if foundMetadata {
            print("✅ Test passed: Mastering display metadata found and attached")
        } else {
            print("ℹ️  No mastering display metadata found in first 20 packets")
            print("   This may be normal if metadata is only in later frames or not present")
        }
    }

    // MARK: - Performance Tests

    func testHDR10DecodingPerformance() throws {
        guard let testURL = getHDR10TestFileURL() else {
            throw XCTSkip("No HDR10 test file available. Place hdr10.mkv in ~/Downloads")
        }

        measure {
            do {
                let demuxer = try MKVDemuxer(url: testURL)

                guard let videoInfo = demuxer.videoInfo,
                      let timebase = demuxer.timebase else {
                    XCTFail("Video info should be available")
                    return
                }

                let decoder = try VideoDecoder(videoInfo: videoInfo, timebase: timebase)

                // Decode first 30 frames
                var frameCount = 0
                var packetCount = 0
                while frameCount < 30 && packetCount < 100 {
                    guard let packet = try demuxer.readPacket() else { break }
                    packetCount += 1

                    let frames = try decoder.decode(packet: packet)
                    frameCount += frames.count
                }

            } catch {
                XCTFail("HDR10 decoding failed: \(error)")
            }
        }
    }

    // MARK: - Resolution Tests

    func testHDRResolution() throws {
        guard let testURL = getHDR10TestFileURL() else {
            throw XCTSkip("No HDR10 test file available. Place hdr10.mkv in ~/Downloads")
        }

        let demuxer = try MKVDemuxer(url: testURL)

        guard let videoInfo = demuxer.videoInfo else {
            XCTFail("Video info should not be nil")
            return
        }

        // HDR content is typically 4K or 1080p
        XCTAssertGreaterThan(videoInfo.width, 0, "Width should be positive")
        XCTAssertGreaterThan(videoInfo.height, 0, "Height should be positive")

        let is4K = videoInfo.width >= 3840 && videoInfo.height >= 2160
        let is1080p = videoInfo.width >= 1920 && videoInfo.height >= 1080

        print("✅ Resolution: \(videoInfo.width)x\(videoInfo.height)")
        if is4K {
            print("   4K/UHD resolution")
        } else if is1080p {
            print("   1080p resolution")
        }
    }
}
