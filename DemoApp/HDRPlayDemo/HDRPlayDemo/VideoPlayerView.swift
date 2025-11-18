//
//  VideoPlayerView.swift
//  HDRPlayDemo
//
//  Phase 2.1 - AVSampleBufferDisplayLayer Integration
//

import SwiftUI
import AVFoundation
internal import Combine
import HDRPlay
internal import CFFmpeg

/// A SwiftUI view that plays video using AVSampleBufferDisplayLayer
///
/// Architecture:
/// 1. Wraps UIViewRepresentable (iOS/tvOS) to expose UIKit layer
/// 2. Uses AVSampleBufferDisplayLayer for frame presentation
/// 3. Manages timing and synchronization for smooth playback
/// 4. Connects HDRPlay (CVPixelBuffers) to AVFoundation (CMSampleBuffers)
struct VideoPlayerView: View {
    let url: URL
    @StateObject private var player = VideoPlayerController()
    @State private var isViewReady = false

    var body: some View {
        ZStack {
            // The actual video rendering layer
            VideoLayerView(player: player, onReady: {
                // Load video after the display layer is set up
                if !isViewReady {
                    isViewReady = true
                    player.load(url: url)
                }
            })
            .background(Color.black)

            // Error overlay
            if let error = player.error {
                VStack {
                    Text("Playback Error")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding()
                }
                .padding()
                .background(Color.black.opacity(0.8))
                .cornerRadius(12)
            }

            // Playback controls overlay
            VStack {
                Spacer()

                HStack(spacing: 20) {
                    Button(action: { player.togglePlayPause() }) {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                            .foregroundColor(.white)
                    }

                    Text(formatTime(player.currentTime))
                        .foregroundColor(.white)
                        .font(.caption)
                }
                .padding()
                .background(Color.black.opacity(0.5))
                .cornerRadius(10)
                .padding(.bottom, 20)
            }
        }
        .navigationTitle("Video Player")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

// MARK: - Video Layer View (UIKit Bridge)

/// Bridges UIKit's AVSampleBufferDisplayLayer into SwiftUI
struct VideoLayerView: UIViewRepresentable {
    let player: VideoPlayerController
    let onReady: () -> Void

    func makeUIView(context: Context) -> VideoDisplayView {
        let view = VideoDisplayView()
        player.displayLayer = view.displayLayer

        // Call ready callback after display layer is set
        DispatchQueue.main.async {
            onReady()
        }

        return view
    }

    func updateUIView(_ uiView: VideoDisplayView, context: Context) {
        // Update view if needed when SwiftUI state changes
    }
}

/// UIView that hosts the AVSampleBufferDisplayLayer
class VideoDisplayView: UIView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }

    private func setupLayer() {
        // Configure the display layer
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = bounds

        // Add to view hierarchy
        layer.addSublayer(displayLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
    }
}

// MARK: - Video Player Controller

/// Controller that manages video playback state and coordinates between
/// HDRPlay (demuxing/decoding) and AVSampleBufferDisplayLayer (presentation)
@MainActor
class VideoPlayerController: ObservableObject {
    // MARK: - Published State

    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0.0
    @Published var duration: Double = 0.0
    @Published var error: Error?

    // MARK: - Private Properties

    /// The display layer for rendering (set by VideoLayerView)
    var displayLayer: AVSampleBufferDisplayLayer?

    /// The actual renderer - accessed via displayLayer.sampleBufferRenderer
    private var renderer: AVSampleBufferVideoRenderer? {
        return displayLayer?.sampleBufferRenderer
    }

    /// HDRPlay components
    private var demuxer: MKVDemuxer?
    private var decoder: VideoDecoder?

    /// Playback timing
    private var displayLink: CADisplayLink?
    private var startTime: CMTime?
    private var timebase: AVRational?

    /// Control center for sample buffer timing
    private var controlTimebase: CMTimebase?

    /// Background queue for decoding
    private let decodingQueue = DispatchQueue(label: "com.hdrplay.decoding", qos: .userInitiated)

    // MARK: - Lifecycle

    init() {
        setupControlTimebase()
    }

    deinit {
        // Cleanup without main actor isolation
        // Can't call stopPlayback() because it's @MainActor isolated
        displayLink?.invalidate()

        // Note: displayLayer and other @MainActor properties
        // will be cleaned up automatically when the actor is deallocated
    }

    // MARK: - Setup

    private func setupControlTimebase() {
        // Create a timebase for controlling playback rate
        // This is crucial for AVSampleBufferDisplayLayer timing
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        self.controlTimebase = timebase

        // Set the timebase rate to 0.0 (paused initially)
        if let timebase = controlTimebase {
            CMTimebaseSetRate(timebase, rate: 0.0)
        }
    }

    // MARK: - Public API

    /// Load a video file and prepare for playback
    func load(url: URL) {
        Task {
            do {
                print("📂 Loading video: \(url.lastPathComponent)")

                // Initialize HDRPlay components
                let demuxer = try MKVDemuxer(url: url)
                self.demuxer = demuxer

                guard let videoInfo = demuxer.videoInfo,
                      let timebase = demuxer.timebase else {
                    throw VideoPlayerError.noVideoStream
                }

                self.timebase = timebase

                // Calculate duration
                if let durationSeconds = demuxer.duration {
                    self.duration = durationSeconds
                }

                // Initialize decoder
                let decoder = try VideoDecoder(videoInfo: videoInfo, timebase: timebase)
                self.decoder = decoder

                // Configure display layer with timebase
                if let displayLayer = displayLayer,
                   let controlTimebase = controlTimebase {
                    displayLayer.controlTimebase = controlTimebase
                }

                print("✅ Video loaded: \(videoInfo.width)x\(videoInfo.height)")
                print("   HDR10: \(videoInfo.isHDR10), HLG: \(videoInfo.isHLG)")
                print("   Duration: \(String(format: "%.2f", duration))s")

            } catch {
                print("❌ Failed to load video: \(error)")
                self.error = error
            }
        }
    }

    /// Toggle between play and pause
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Start playback
    func play() {
        guard !isPlaying else { return }

        print("▶️  Starting playback")
        isPlaying = true

        // Set timebase rate to 1.0 (normal playback speed)
        if let timebase = controlTimebase {
            CMTimebaseSetRate(timebase, rate: 1.0)
        }

        // Start decoding and enqueuing frames
        startDecodingLoop()

        // Start display link for time updates
        startDisplayLink()
    }

    /// Pause playback
    func pause() {
        guard isPlaying else { return }

        print("⏸  Pausing playback")
        isPlaying = false

        // Set timebase rate to 0.0 (paused)
        if let timebase = controlTimebase {
            CMTimebaseSetRate(timebase, rate: 0.0)
        }

        stopDisplayLink()
    }

    /// Stop playback and cleanup
    func stopPlayback() {
        pause()

        // Flush renderer using protocol method
        renderer?.flush()

        // Reset demuxer and decoder
        demuxer = nil
        decoder = nil

        print("⏹  Stopped playback")
    }

    // MARK: - Decoding Loop

    private func startDecodingLoop() {
        Task { [weak self] in
            await self?.decodingLoop()
        }
    }

    /// Main decoding loop - runs on main actor but uses async operations
    private func decodingLoop() async {
        // Capture references on main actor
        guard let demuxer = demuxer,
              let decoder = decoder,
              let renderer = renderer,
              let timebase = timebase else {
            print("❌ Missing required components for decoding")
            return
        }

        print("🎬 Decoding loop starting...")
        print("   Demuxer: \(demuxer)")
        print("   Decoder: \(decoder)")
        print("   Renderer: \(renderer)")

        // Run the actual decoding work off the main actor
        await Task.detached { [weak self] in
            guard let self = self else { return }

            do {
                actor FrameCounter {
                    var count = 0

                    func increment() -> Int {
                        count += 1
                        return count
                    }
                }

                let frameCounter = FrameCounter()

                // Read and decode packets
                while await self.shouldContinueDecoding() {
                    // Read packet (FFmpeg operation - can be done off main thread)
                    guard let packet = try demuxer.readPacket() else {
                        print("📭 Reached end of file")
                        await MainActor.run {
                            self.isPlaying = false
                        }
                        break
                    }

                    // Decode packet to frames (FFmpeg operation - off main thread)
                    let frames = try decoder.decode(packet: packet)

                    // Convert and enqueue each frame
                    for frame in frames {
                        // Create sample buffer
                        let sampleBuffer = try await self.createSampleBuffer(
                            from: frame,
                            timebase: timebase
                        )

                        // Enqueue on main actor (AVFoundation requires main thread)
                        await MainActor.run {
                            renderer.enqueue(sampleBuffer)
                        }

                        // Increment counter
                        let currentCount = await frameCounter.increment()

                        if currentCount % 30 == 0 {
                            print("📽️  Enqueued \(currentCount) frames...")
                        }

                        // Check if renderer is ready for more
                        let readyForMoreMediaData = await MainActor.run {
                            renderer.isReadyForMoreMediaData
                        }

                        if !readyForMoreMediaData {
                            // Wait a bit before enqueuing more
                            try? await Task.sleep(nanoseconds: 16_000_000) // ~16ms
                        }
                    }
                }

                let totalFrames = await frameCounter.count
                print("✅ Decoding loop completed. Total frames: \(totalFrames)")

            } catch {
                await MainActor.run {
                    self.error = error
                    self.isPlaying = false
                }
                print("❌ Decoding error: \(error)")
            }
        }.value
    }

    /// Check if decoding should continue (thread-safe)
    private func shouldContinueDecoding() async -> Bool {
        await MainActor.run {
            return self.isPlaying
        }
    }

    /// Convert a DecodedFrame (CVPixelBuffer + timing) to CMSampleBuffer
    private func createSampleBuffer(from frame: DecodedFrame, timebase: AVRational) throws -> CMSampleBuffer {

        // STEP 1: Create CMVideoFormatDescription from CVPixelBuffer
        // This describes the video format (dimensions, pixel format, color space)
        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.pixelBuffer,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let formatDescription = formatDescription else {
            print("❌ Failed to create format description: \(status)")
            throw VideoPlayerError.sampleBufferCreationFailed
        }

        // STEP 2: Create CMSampleTimingInfo from frame timing
        // Convert FFmpeg's AVRational timebase + pts/duration to CMTime

        // Presentation timestamp (when to display this frame)
        let presentationTime = CMTime(
            value: frame.pts,
            timescale: CMTimeScale(timebase.den)
        )

        // Decode timestamp (when this frame was decoded - usually same as pts for video)
        let decodeTime = presentationTime

        // Duration (how long to display this frame)
        let duration = CMTime(
            value: frame.duration,
            timescale: CMTimeScale(timebase.den)
        )

        var timingInfo = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: decodeTime
        )

        // STEP 3: Create CMSampleBuffer
        // This combines the pixel buffer, format description, and timing
        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        guard createStatus == noErr, let sampleBuffer = sampleBuffer else {
            print("❌ Failed to create sample buffer: \(createStatus)")
            throw VideoPlayerError.sampleBufferCreationFailed
        }

        // Optional: Attach additional metadata
        // Mark keyframes for seeking
        if frame.isKeyFrame {
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: true
            ) as? [[CFString: Any]]

            if let attachments = attachments, attachments.count > 0 {
                var attachment = attachments[0]
                attachment[kCMSampleAttachmentKey_DependsOnOthers] = false
            }
        }

        return sampleBuffer
    }

    // MARK: - Display Link (Time Updates)

    private func startDisplayLink() {
        stopDisplayLink()

        let displayLink = CADisplayLink(target: self, selector: #selector(displayLinkCallback))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkCallback() {
        // Update current time from control timebase
        if let timebase = controlTimebase {
            let time = CMTimebaseGetTime(timebase)
            currentTime = CMTimeGetSeconds(time)
        }
    }
}

// MARK: - Errors

enum VideoPlayerError: Error {
    case noVideoStream
    case displayLayerNotReady
    case decodingFailed
    case sampleBufferCreationFailed
}

// MARK: - Preview

#Preview("Video Player") {
    if let testURL = Bundle.main.url(forResource: "sample", withExtension: "mkv") {
        VideoPlayerView(url: testURL)
    } else {
        Text("No test video found")
            .foregroundColor(.red)
    }
}
