//
//  MKVDemuxerTests.swift
//  hdrplay
//
//  Created by Andrew Sartor on 2025/11/18.
//

import XCTest
@testable import HDRPlay

final class MKVDemuxerTests: XCTestCase {
    
    // MARK: - Test File Setup
    
    // Returns a test MKV file URL if available
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
    // MARK: - Basic Tests

    func testOpenValidMKVFile() throws {
        guard let testURL = getTestFileURL() else {
            throw XCTSkip("No test MKV file available. Place a test.mkv file at /tmp/test.mkv")
        }
            let demuxer = try MKVDemuxer(url: testURL)
            
            XCTAssertNotNil(demuxer)
            print("✅ Successfully opened MKV file")
    }

    func testOpenInvalidFile() {
        let invalidURL = URL(fileURLWithPath: "/nonexistent/file.mkv")
        
        XCTAssertThrowsError(try MKVDemuxer(url: invalidURL)) { error in
            if case DemuxerError.cannotOpenFile = error {
                // Expected
            } else {
                XCTFail("Expected cannotOpenFile error, got \(error)")
            }
        }
    }


    // MARK: - Video Info Tests

    func testVideoInfo() throws {
        guard let testURL = getTestFileURL() else {
            throw XCTSkip("No test MKV file available")
        }
        
        let demuxer = try MKVDemuxer(url: testURL)
        
        guard let videoInfo = demuxer.videoInfo else {
            XCTFail("Video info should not be nil")
            return
        }
        
        XCTAssertGreaterThan(videoInfo.width, 0, "Width should be positive")
        XCTAssertGreaterThan(videoInfo.height, 0, "Height should be positive")
        
        print("Resolution: \(videoInfo.width)x\(videoInfo.height)")
        print("HDR10: \(videoInfo.isHDR10)")
        print("HLG: \(videoInfo.isHLG)")
    }

    func testDuration() throws {
        guard let testURL = getTestFileURL() else {
            throw XCTSkip("No test MKV file available")
        }
        
        let demuxer = try MKVDemuxer(url: testURL)
        
        if let duration = demuxer.duration {
            XCTAssertGreaterThan(duration, 0, "Duration should be positive")
            print("Duration: \(String(format: "%.2f", duration)) seconds")
        } else {
            print ("Duration is not available in this file")
        }
    }
    
    // MARK: - Packet Reading Tests
    
    func testReadFirstPacket() throws {
        guard let testURL = getTestFileURL() else {
            throw XCTSkip("No test MKV file available")
        }
        
        let demuxer = try MKVDemuxer(url: testURL)
        
        guard let packet = try demuxer.readPacket() else {
            XCTFail("Should be able to read at least one packet")
            return
        }
        
        XCTAssertGreaterThan(packet.data.count, 0, "Packet should have data")
        print("first packet: \(packet.data.count) bytes, keyframe: \(packet.isKeyframe)")
    }
    
    func testReadMultiplePackets() throws {
        guard let testURL = getTestFileURL() else {
            throw XCTSkip("No test MKV file available")
        }
        
        let demuxer = try MKVDemuxer(url: testURL)
        
        var packetCount = 0
        var keyframeCount = 0
        let maxPackets = 100
        
        while let packet = try demuxer.readPacket(), packetCount < maxPackets {
            XCTAssertGreaterThan(packet.data.count, 0, "Packet \(packetCount) should be greater than 0")
            
            if packet.isKeyframe {
                keyframeCount += 1
            }
            
            packetCount += 1
        }
        
        XCTAssertGreaterThan(packetCount, 0, "Should read at least one packet")
        XCTAssertGreaterThan(keyframeCount, 0, "Should have at least one keyframe")
        
        print("Read \(packetCount) packets (\(keyframeCount) keyframes)")
    }
    
    func testPacketTiming() throws {
        guard let testURL = getTestFileURL() else {
            throw XCTSkip("No test MKV file available")
        }
        
        let demuxer = try MKVDemuxer(url: testURL)
        
        guard let firstPacket = try demuxer.readPacket() else {
            XCTFail("Should read first packet")
            return
        }
        
        XCTAssertGreaterThanOrEqual(firstPacket.pts, 0, "First packet PTS should be non-negative")
        
        XCTAssertGreaterThan(firstPacket.timebase.den, 0, "Timebase denominator should be positive")
        
        print("First packet timing:")
        print("  PTS: \(firstPacket.pts)")
        print("  DTS: \(firstPacket.dts)")
        print("  Duration: \(firstPacket.duration)")
        print("  Timebase: \(firstPacket.timebase.num)/\(firstPacket.timebase.den)")
    }
    
    func testReadUntilEOF() throws {
        guard let testURL = getTestFileURL() else {
            throw XCTSkip("No test MKV file available")
        }
        
        let demuxer = try MKVDemuxer(url: testURL)
        
        var packetCount = 0
        let maxPackets = 10000 // Safety limit
        
        while let _ = try demuxer.readPacket(), packetCount < maxPackets {
            packetCount += 1
        }
        
        print("Read \(packetCount) total packets until EOF")
        XCTAssertGreaterThan(packetCount, 0, "Should read at least one packet")
    }
    
    // MARK: - Performance Tests
    
    func testDemuxingPerformance() throws {
        guard let testURL = getTestFileURL() else {
            throw XCTSkip("No test MKV file available")
        }
        
        measure {
            do {
                let demuxer = try MKVDemuxer(url: testURL)
                
                // Read first 100 packets
                var count = 0
                while let _ = try demuxer.readPacket(), count < 100 {
                    count += 1
                }
            } catch {
                XCTFail("Demuxing failed: \(error)")
            }
        }
    }
    
    // MARK: - Edge Cases
    
    func testMultipleDemuxerInstances() throws {
        guard let testURL = getTestFileURL() else {
            throw XCTSkip("No test MKV file available")
        }
        
        // Create multiple demuxers for the same file
        let demuxer1 = try MKVDemuxer(url: testURL)
        let demuxer2 = try MKVDemuxer(url: testURL)
        
        // Read from both
        let packet1 = try demuxer1.readPacket()
        let packet2 = try demuxer2.readPacket()
        
        XCTAssertNotNil(packet1)
        XCTAssertNotNil(packet2)
        
        // Both should read the same first packet
        XCTAssertEqual(packet1?.pts, packet2?.pts)
        XCTAssertEqual(packet1?.data.count, packet2?.data.count)
    }

}

