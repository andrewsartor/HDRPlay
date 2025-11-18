# HDRPlay

A Swift package for iOS and tvOS that enables advanced media playback capabilities by bridging FFmpeg with Apple's native video processing pipeline.

## Overview

HDRPlay provides a high-performance backend for media player applications on Apple platforms. It handles container formats and codecs that aren't natively supported by AVFoundation, while leveraging Apple's hardware-accelerated video pipeline for optimal HDR and high-quality video playback.

The library focuses on **remuxing** (container format conversion) rather than transcoding, preserving the original video quality and HDR metadata while making content compatible with Apple's native frameworks.

## Project Goals

### Primary Goal: MKV Container Support
Enable playback of MKV/Matroska video files on iOS and tvOS by:
- Demuxing MKV containers using FFmpeg
- Extracting HEVC/H.264 video streams with HDR metadata preservation
- Presenting video streams to Apple's native video processing pipeline (AVFoundation/VideoToolbox)
- Maintaining full HDR10 and HLG support throughout the pipeline

### Secondary Goal: Advanced Subtitle Support
Extend Apple's subtitle capabilities to support:
- **PGS** (Presentation Graphic Stream) - Blu-ray bitmap subtitles
- **SRT** (SubRip) - Enhanced text subtitle rendering
- **ASS/SSA** (Advanced SubStation Alpha) - Styled subtitle support

### Approach: HLS Remuxing
Initial implementation strategy leverages Apple's native HLS support:
- Remux MKV containers to HLS (HTTP Live Streaming) format
- Utilize Apple's battle-tested HLS playback stack
- Maintain HDR metadata and quality through the remux process
- Enable seamless integration with AVPlayer and native playback controls

## Current Status

✅ **Completed:**
- FFmpeg integration (libavformat, libavcodec, libavutil, libswscale, libswresample)
- MKV demuxing with full stream information
- HDR metadata extraction (HDR10, HLG detection)
- HEVC/H.264 decoder support
- Cross-platform builds (iOS, tvOS, macOS, all simulators)
- Comprehensive test suite

🚧 **In Progress:**
- Video frame decoding and CVPixelBuffer conversion
- Integration with AVFoundation playback

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Your Media App                       │
└─────────────────────────────────────────────────────────┘
                           │
                           ↓
┌─────────────────────────────────────────────────────────┐
│                      HDRPlay                            │
│  ┌──────────────┐    ┌──────────────┐                   │
│  │ MKVDemuxer   │ -> │ VideoDecoder │                   │
│  │ (FFmpeg)     │    │ (FFmpeg)     │                   │
│  └──────────────┘    └──────────────┘                   │
│         │                    │                          │
│         ↓                    ↓                          │
│  Extract Streams      CVPixelBuffer Conversion          │
└─────────────────────────────────────────────────────────┘
                           │
                           ↓
┌─────────────────────────────────────────────────────────┐
│              Apple Native Pipeline                      │
│  AVFoundation | VideoToolbox | Core Video | Metal       │
└─────────────────────────────────────────────────────────┘
```

## Installation

### Swift Package Manager

Add HDRPlay to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/andrewsartor/hdrplay.git", from: "0.1.0")
]
```

Or add it in Xcode:
1. File → Add Package Dependencies
2. Enter the repository URL
3. Select version/branch

### Requirements

- iOS 14.0+ / tvOS 14.0+ / macOS 11.0+
- Xcode 15.0+
- Swift 6.2+

## Quick Start

```swift
import HDRPlay

// Open an MKV file
let demuxer = try MKVDemuxer(url: videoURL)

// Get video information
if let videoInfo = demuxer.videoInfo {
    print("Resolution: \(videoInfo.width)×\(videoInfo.height)")
    print("HDR10: \(videoInfo.isHDR10)")
    print("HLG: \(videoInfo.isHLG)")
}

// Create decoder
guard let timebase = demuxer.timebase else { return }
let decoder = try VideoDecoder(videoInfo: videoInfo, timebase: timebase)

// Read and decode packets
while let packet = try demuxer.readPacket() {
    let frames = try decoder.decode(packet: packet)

    for frame in frames {
        // frame.pixelBuffer is a CVPixelBuffer ready for display
        // Use with AVSampleBufferDisplayLayer or Metal
    }
}
```

## Development Roadmap

This roadmap is designed for incremental implementation, with each phase building on the previous one.

### Phase 1: Foundation ✅ **COMPLETE**
**Goal:** Establish FFmpeg integration and basic demuxing

- [x] Set up Swift Package with FFmpeg XCFrameworks
- [x] Create C bridge (CFFmpeg) for FFmpeg APIs
- [x] Implement MKVDemuxer for container parsing
- [x] Extract video stream metadata and HDR information
- [x] Build comprehensive test suite
- [x] Implement VideoDecoder with extradata support

**Outcome:** Can open MKV files, read metadata, and extract encoded packets.

---

### Phase 2: Basic Playback Integration 🎯 **NEXT**
**Goal:** Display decoded video frames using Apple's native pipeline

**2.1 - AVSampleBufferDisplayLayer Integration**
- [ ] Create `VideoPlayer` class wrapping AVSampleBufferDisplayLayer
- [ ] Implement timing and synchronization for frame presentation
- [ ] Handle sample buffer creation from CVPixelBuffer + timing info
- [ ] Add basic playback controls (play, pause, seek)
- [ ] Create demo app with simple video player UI

**2.2 - HDR Display Configuration**
- [ ] Proper CVPixelBuffer format selection (10-bit for HDR)
- [ ] HDR metadata attachment to sample buffers
- [ ] Color space configuration for HDR10/HLG
- [ ] Test with real HDR content on HDR-capable devices

**Learning Resources:**
- Apple's AVSampleBufferDisplayLayer documentation
- WWDC videos on HDR playback
- Core Video pixel format types

**Success Criteria:** Play MKV files with HDR content in demo app

---

### Phase 3: HLS Remuxing
**Goal:** Convert MKV to HLS for seamless AVPlayer integration

**3.1 - HLS Segment Generation**
- [ ] Research HLS container format (MPEG-TS segments)
- [ ] Implement segment writer using FFmpeg muxers
- [ ] Generate M3U8 playlist files
- [ ] Handle segment duration and GOP alignment

**3.2 - In-Memory HLS Serving**
- [ ] Create local HTTP server for HLS delivery
- [ ] Serve segments and playlists to AVPlayer
- [ ] Implement segment caching and cleanup
- [ ] Handle seeking and random access

**3.3 - AVPlayer Integration**
- [ ] Replace AVSampleBufferDisplayLayer with AVPlayer
- [ ] Expose standard AVPlayer controls
- [ ] Test with AVPlayerViewController (iOS) and AVPlayerView (tvOS)

**Learning Resources:**
- HLS specification (RFC 8216)
- FFmpeg HLS muxer documentation
- Apple's HTTP Live Streaming guide

**Success Criteria:** Smooth playback of MKV files through AVPlayer with native controls

---

### Phase 4: Subtitle Support
**Goal:** Add PGS, SRT, and ASS subtitle rendering

**4.1 - Subtitle Track Extraction**
- [ ] Extend demuxer to identify subtitle streams
- [ ] Parse PGS (bitmap) subtitle packets
- [ ] Parse SRT (text) subtitle files
- [ ] Parse ASS/SSA (styled text) subtitles

**4.2 - Subtitle Rendering**
- [ ] PGS: Decode bitmap graphics and overlay on video
- [ ] SRT: Implement text rendering with Core Text
- [ ] ASS: Parse style tags and render with formatting
- [ ] Timing synchronization with video playback

**4.3 - HLS Subtitle Integration**
- [ ] Embed WebVTT subtitles in HLS stream
- [ ] Generate subtitle variant playlists
- [ ] Enable AVPlayer's native subtitle selection

**Learning Resources:**
- PGS format specification
- WebVTT specification
- Core Text rendering
- ASS/SSA format documentation

**Success Criteria:** Display subtitles from MKV files with proper timing and styling

---

### Phase 5: Performance & Polish
**Goal:** Optimize for production use

- [ ] Memory profiling and leak detection
- [ ] Thread safety and concurrent decoding
- [ ] Background playback support
- [ ] AirPlay and external display handling
- [ ] Comprehensive error handling and recovery
- [ ] Performance benchmarking suite
- [ ] API documentation and usage examples

---

### Phase 6: Advanced Features (Future)
**Goal:** Extended codec and format support

- [ ] Audio track handling and switching
- [ ] Multi-audio track support
- [ ] Chapter markers and navigation
- [ ] Dolby Vision support (if feasible)
- [ ] Additional container formats (MP4, AVI)
- [ ] Hardware decoder fallback strategies

## Building from Source

### Prerequisites

1. Xcode 15.0 or later
2. FFmpeg source (automatically downloaded by build script)

### Build FFmpeg Libraries

```bash
# Build for all platforms (iOS, tvOS, macOS, simulators)
./Scripts/build-ffmpeg-all.sh

# Create XCFrameworks
./Scripts/create-xcframework.sh
```

This process takes 30-60 minutes depending on your machine. The scripts will:
- Download FFmpeg 8.0 source
- Build for all Apple platforms and architectures
- Create universal binaries for simulators
- Package into XCFrameworks

### Build the Swift Package

```bash
# Build package
swift build

# Run tests
swift test

# Run demo app
open DemoApp/HDRPlayDemo/HDRPlayDemo.xcodeproj
```

## Contributing

This is currently a personal learning project, but suggestions and feedback are welcome! Please open an issue to discuss major changes.

### Development Setup

1. Clone the repository
2. Run `swift build` to verify setup
3. Place a test MKV file at `/tmp/test.mkv` for running tests
4. Open `DemoApp/HDRPlayDemo/HDRPlayDemo.xcodeproj` in Xcode

## Resources & Learning

### FFmpeg
- [FFmpeg Documentation](https://ffmpeg.org/documentation.html)
- [FFmpeg API Examples](https://github.com/FFmpeg/FFmpeg/tree/master/doc/examples)

### Apple Video Frameworks
- [AVFoundation Programming Guide](https://developer.apple.com/av-foundation/)
- [Core Video Programming Guide](https://developer.apple.com/documentation/corevideo)
- [HDR Video on Apple Platforms](https://developer.apple.com/videos/play/wwdc2017/508/)

### Swift Package Development
- [Swift Package Manager Documentation](https://swift.org/package-manager/)
- [Creating a Swift Package](https://developer.apple.com/documentation/xcode/creating-a-standalone-swift-package-with-xcode)

## License

[To be determined]
