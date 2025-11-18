//
//  ContentView.swift
//  HDRPlayDemo
//
//  Created by Andrew Sartor on 2025/11/18.
//

import SwiftUI
import HDRPlay
import UniformTypeIdentifiers
internal import Combine
internal import CFFmpeg

struct ContentView: View {
    @StateObject private var viewModel = VideoTestViewModel()
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    Text("HDRPlayerKit Demo")
                        .font(.title)
                        .padding()
                    
                    // File picker button
                    Button("Select MKV File") {
                        viewModel.showFilePicker = true
                    }
                    .buttonStyle(.borderedProminent)
                    .fileImporter(
                        isPresented: $viewModel.showFilePicker,
                        allowedContentTypes: [.movie, .video, .quickTimeMovie, makeMatroskaUTType()],
                        allowsMultipleSelection: false
                    ) { result in
                        viewModel.handleFileSelection(result)
                    }
                    
                    // Status display
                    if viewModel.isLoading {
                        ProgressView("Loading file...")
                    }
                    
                    if let error = viewModel.errorMessage {
                        Text("Error: \(error)")
                            .foregroundColor(.red)
                            .padding()
                    }
                    
                    // File info display
                    if let info = viewModel.fileInfo {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("File Information")
                                .font(.headline)
                            
                            InfoRow(label: "Filename", value: info.filename)
                            InfoRow(label: "Resolution", value: info.resolution)
                            InfoRow(label: "Duration", value: info.duration)
                            InfoRow(label: "Codec", value: info.codec)
                            InfoRow(label: "HDR", value: info.hdrType)
                            
                            if !info.colorInfo.isEmpty {
                                Text("Color Information")
                                    .font(.subheadline)
                                    .padding(.top, 8)
                                
                                ForEach(info.colorInfo, id: \.label) { item in
                                    InfoRow(label: item.label, value: item.value, isDetail: true)
                                }
                            }
                        }
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(12)
                        .padding()
                    }
                    
                    // Packet reading test
                    if viewModel.fileInfo != nil {
                        Button("Read First 10 Packets") {
                            viewModel.testPacketReading()
                        }
                        .buttonStyle(.bordered)
                        
                        if !viewModel.packetInfo.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Packets Read")
                                    .font(.headline)
                                
                                ForEach(Array(viewModel.packetInfo.enumerated()), id: \.offset) { index, packet in
                                    HStack {
                                        Text("Packet \(index)")
                                            .font(.caption)
                                            .frame(width: 60, alignment: .leading)
                                        Text(packet)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding()
                            .background(Color.blue.opacity(0.05))
                            .cornerRadius(8)
                            .padding()
                        }
                    }
                    
                    if viewModel.fileInfo != nil {
                        Button("Decode First Frame") {
                            viewModel.testDecoding()
                        }
                        .buttonStyle(.bordered)
                        
                        if let frame = viewModel.currentFrame {
                            Text("✅ Decoded frame! \(viewModel.frameCount) frames")
                                .foregroundColor(.green)
                            
                            PixelBufferView(pixelBuffer: frame)
                                .frame(width: 300, height: 169)
                                .cornerRadius(8)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("MKV Test")
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var isDetail: Bool = false
    
    var body: some View {
        HStack {
            Text(label + ":")
                .font(isDetail ? .caption : .body)
                .foregroundColor(.secondary)
                .frame(width: isDetail ? 150 : 120, alignment: .leading)
            Text(value)
                .font(isDetail ? .caption : .body)
                .bold(!isDetail)
        }
    }
}

struct FileInfo {
    let filename: String
    let resolution: String
    let duration: String
    let codec: String
    let hdrType: String
    let colorInfo: [(label: String, value: String)]
}

@MainActor
class VideoTestViewModel: ObservableObject {
    @Published var showFilePicker = false
    @Published var fileInfo: FileInfo?
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var packetInfo: [String] = []
    @Published var currentFrame: CVPixelBuffer?
    @Published var frameCount: Int = 0
    
    private var demuxer: MKVDemuxer?
    private var fileURL: URL?
    
    func testDecoding() {
        Task {
            do {
                guard let demuxer = demuxer,
                      let videoInfo = demuxer.videoInfo else {
                    errorMessage = "No video info available"
                    return
                }
                
                let decoder = try VideoDecoder(
                    videoInfo: videoInfo,
                    timebase: demuxer.timebase ?? AVRational(num: 1, den: 1000000)
                )
                
                while let packet = try demuxer.readPacket() {
                    let frames = try decoder.decode(packet: packet)
                    
                    if let firstFrame = frames.first {
                        currentFrame = firstFrame.pixelBuffer
                        frameCount += frames.count
                        break
                    }
                }
            } catch {
                errorMessage = "Decoding error: \(error.localizedDescription)"
            }
        }
    }
    
    func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            
            // Get access to the file
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Cannot access file"
                return
            }
            
            self.fileURL = url
            loadFile(url: url)
            
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
    
    func loadFile(url: URL) {
        isLoading = true
        errorMessage = nil
        fileInfo = nil
        packetInfo = []
        
        Task {
            do {
                let demuxer = try MKVDemuxer(url: url)
                self.demuxer = demuxer
                
                // Extract file info
                var colorInfo: [(String, String)] = []
                
                if let videoInfo = demuxer.videoInfo {
                    colorInfo = [
                        ("Color Transfer", "\(videoInfo.colorTransfer.rawValue)"),
                        ("Color Primaries", "\(videoInfo.colorPrimaries.rawValue)"),
                        ("Is HDR10", videoInfo.isHDR10 ? "Yes" : "No"),
                        ("Is HLG", videoInfo.isHLG ? "Yes" : "No")
                    ]
                    
                    let hdrType: String
                    if videoInfo.isHDR10 {
                        hdrType = "HDR10"
                    } else if videoInfo.isHLG {
                        hdrType = "HLG"
                    } else {
                        hdrType = "SDR"
                    }
                    
                    fileInfo = FileInfo(
                        filename: url.lastPathComponent,
                        resolution: "\(videoInfo.width)×\(videoInfo.height)",
                        duration: formatDuration(demuxer.duration),
                        codec: "HEVC", // You could add codec name to VideoInfo
                        hdrType: hdrType,
                        colorInfo: colorInfo
                    )
                }
                
                isLoading = false
                
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }
    
    func testPacketReading() {
        packetInfo = []
        
        Task {
            do {
                guard let demuxer = demuxer else { return }
                
                // Read first 10 packets
                for _ in 0..<10 {
                    if let packet = try demuxer.readPacket() {
                        let info = "\(packet.data.count) bytes, " +
                                   "keyframe: \(packet.isKeyframe ? "✓" : "✗"), " +
                                   "pts: \(packet.pts)"
                        packetInfo.append(info)
                    } else {
                        break // EOF
                    }
                }
                
                if packetInfo.isEmpty {
                    errorMessage = "Could not read any packets"
                }
                
            } catch {
                errorMessage = "Error reading packets: \(error.localizedDescription)"
            }
        }
    }
    
    private func formatDuration(_ duration: Double?) -> String {
        guard let duration = duration else { return "Unknown" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    deinit {
        fileURL?.stopAccessingSecurityScopedResource()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

// MARK: - Helpers
private func makeMatroskaUTType() -> UTType {
    // MKV/Matroska UTType
    UTType(filenameExtension: "mkv") ?? .movie
}

// MARK: - Previews

#Preview("Empty State") {
    ContentView()
}

#Preview("Loading State") {
    ContentViewPreview(isLoading: true)
}

#Preview("With File Info") {
    ContentViewPreview(
        fileInfo: FileInfo(
            filename: "sample_4k_hdr.mkv",
            resolution: "3840×2160",
            duration: "2:15",
            codec: "HEVC",
            hdrType: "HDR10",
            colorInfo: [
                ("Color Transfer", "16"),
                ("Color Primaries", "9"),
                ("Is HDR10", "Yes"),
                ("Is HLG", "No")
            ]
        )
    )
}

#Preview("Error State") {
    ContentViewPreview(errorMessage: "Failed to open file: File not found")
}

#Preview("With Packets") {
    ContentViewPreview(
        fileInfo: FileInfo(
            filename: "test.mkv",
            resolution: "1920×1080",
            duration: "1:30",
            codec: "HEVC",
            hdrType: "SDR",
            colorInfo: []
        ),
        packetInfo: [
            "125432 bytes, keyframe: ✓, pts: 0",
            "42156 bytes, keyframe: ✗, pts: 3003",
            "38921 bytes, keyframe: ✗, pts: 6006"
        ]
    )
}


private struct ContentViewPreview: View {
    @StateObject private var viewModel = PreviewViewModel()
    
    init(
        isLoading: Bool = false,
        fileInfo: FileInfo? = nil,
        errorMessage: String? = nil,
        packetInfo: [String] = []
    ) {
        _viewModel = StateObject(wrappedValue: PreviewViewModel(
            isLoading: isLoading,
            fileInfo: fileInfo,
            errorMessage: errorMessage,
            packetInfo: packetInfo
        ))
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    Text("HDRPlay Demo")
                        .font(.title)
                        .padding()
                    
                    if viewModel.isLoading {
                        ProgressView("Loading file...")
                    }
                    
                    if let error = viewModel.errorMessage {
                        Text("Error: \(error)")
                            .foregroundColor(.red)
                            .padding()
                    }
                    
                    if let info = viewModel.fileInfo {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("File Information")
                                .font(.headline)
                            
                            InfoRow(label: "Filename", value: info.filename)
                            InfoRow(label: "Resolution", value: info.resolution)
                            InfoRow(label: "Duration", value: info.duration)
                            InfoRow(label: "Codec", value: info.codec)
                            InfoRow(label: "HDR", value: info.hdrType)
                            
                            if !info.colorInfo.isEmpty {
                                Text("Color Information")
                                    .font(.subheadline)
                                    .padding(.top, 8)
                                
                                ForEach(info.colorInfo, id: \.label) { item in
                                    InfoRow(label: item.label, value: item.value, isDetail: true)
                                }
                            }
                        }
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(12)
                        .padding()
                    }
                    
                    if !viewModel.packetInfo.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Packets Read")
                                .font(.headline)
                            
                            ForEach(Array(viewModel.packetInfo.enumerated()), id: \.offset) { index, packet in
                                    HStack {
                                        Text("Packet \(index)")
                                            .font(.caption)
                                            .frame(width: 60, alignment: .leading)
                                        Text(packet)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding()
                        .background(Color.blue.opacity(0.05))
                        .cornerRadius(8)
                        .padding()
                    }
                }
                .padding()
            }
            .navigationTitle("MKV Test")
        }
    }
}

@MainActor
private class PreviewViewModel: ObservableObject {
    @Published var isLoading: Bool
    @Published var fileInfo: FileInfo?
    @Published var errorMessage: String?
    @Published var packetInfo: [String]
    
    init (
        isLoading: Bool = false,
        fileInfo: FileInfo? = nil,
        errorMessage: String? = nil,
        packetInfo: [String] = []
    ) {
        self.isLoading = isLoading
        self.fileInfo = fileInfo
        self.errorMessage = errorMessage
        self.packetInfo = packetInfo
    }
}
