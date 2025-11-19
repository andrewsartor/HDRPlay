//
//  VideoToolboxDecoder.swift
//  HDRPlay
//
//  Hardware-accelerated video decoder using VideoToolbox
//

import AVFoundation
import CoreMedia
import VideoToolbox
import CFFmpeg

public enum VideoToolboxDecoderError: Error {
    case cannotCreateFormatDescription
    case cannotCreateDecompressionSession
    case cannotCreateSampleBuffer
    case cannotCreateBlockBuffer
    case decodingFailed(status: OSStatus)
    case missingExtradata
    case invalidTimingInfo
}

public class VideoToolboxDecoder {
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    private let videoInfo: VideoInfo
    private let timebase: AVRational

    // Decoded frames buffer (callback appends here)
    private var pendingFrames: [DecodedFrame] = []
    private let frameQueue = DispatchQueue(label: "com.hdrplay.framequeue")

    // Track if we've logged pixel format info
    private var hasLoggedPixelFormat = false

    public init(videoInfo: VideoInfo, timebase: AVRational) throws {
        self.videoInfo = videoInfo
        self.timebase = timebase

        print("🔧 Initializing VideoToolbox decoder...")
        print("   Codec: \(videoInfo.codecID.rawValue)")
        print("   Resolution: \(videoInfo.width)x\(videoInfo.height)")
        print("   Pixel Format: \(videoInfo.pixelFormat.rawValue)")
        print("   Extradata size: \(videoInfo.extradata?.count ?? 0) bytes")

        // Create format description from extradata
        do {
            self.formatDescription = try Self.createFormatDescription(
                codecType: videoInfo.codecID,
                width: videoInfo.width,
                height: videoInfo.height,
                extradata: videoInfo.extradata
            )
            print("   ✅ Format description created")
        } catch {
            print("   ❌ Failed to create format description: \(error)")
            throw error
        }

        // Create decompression session
        do {
            try createDecompressionSession()
            print("   ✅ Decompression session created")
        } catch {
            print("   ❌ Failed to create decompression session: \(error)")
            throw error
        }

        print("✅ VideoToolbox decoder initialized: \(videoInfo.width)x\(videoInfo.height)")
    }

    // MARK: - Format Description Creation

    private static func createFormatDescription(
        codecType: AVCodecID,
        width: Int,
        height: Int,
        extradata: Data?
    ) throws -> CMFormatDescription {
        guard let extradata = extradata, !extradata.isEmpty else {
            throw VideoToolboxDecoderError.missingExtradata
        }

        // Handle different codec types
        switch codecType {
        case AV_CODEC_ID_HEVC:
            return try createHEVCFormatDescription(extradata: extradata)
        case AV_CODEC_ID_H264:
            return try createH264FormatDescription(extradata: extradata)
        default:
            print("⚠️ Unsupported codec type: \(codecType.rawValue)")
            throw VideoToolboxDecoderError.cannotCreateFormatDescription
        }
    }

    // Create format description for HEVC
    private static func createHEVCFormatDescription(extradata: Data) throws -> CMFormatDescription {
        print("📦 Parsing HEVC extradata (hvcC format)...")
        print("   Size: \(extradata.count) bytes")
        print("   First 32 bytes: \(extradata.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " "))")

        // Try parsing parameter sets from hvcC
        let parameterSets = try parseHEVCParameterSets(from: extradata)

        guard !parameterSets.isEmpty else {
            print("❌ No parameter sets found in extradata")
            throw VideoToolboxDecoderError.cannotCreateFormatDescription
        }

        print("   Found \(parameterSets.count) parameter set(s)")

        var formatDesc: CMFormatDescription?

        // Call the Core Media API with proper pointer lifetime
        let status = createFormatDescriptionFromParameterSets(
            parameterSets: parameterSets,
            formatDescriptionOut: &formatDesc
        )

        guard status == noErr, let formatDesc = formatDesc else {
            print("❌ CMVideoFormatDescriptionCreateFromHEVCParameterSets failed with status: \(status)")
            throw VideoToolboxDecoderError.cannotCreateFormatDescription
        }

        print("   ✅ Successfully created HEVC format description from \(parameterSets.count) parameter sets")
        return formatDesc
    }

    // Create format description for H.264
    private static func createH264FormatDescription(extradata: Data) throws -> CMFormatDescription {
        print("📦 Parsing H.264 extradata (avcC format)...")
        print("   Size: \(extradata.count) bytes")
        print("   First 32 bytes: \(extradata.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " "))")

        // Parse parameter sets from avcC (similar structure to hvcC but simpler)
        let parameterSets = try parseH264ParameterSets(from: extradata)

        guard !parameterSets.isEmpty else {
            print("❌ No parameter sets found in extradata")
            throw VideoToolboxDecoderError.cannotCreateFormatDescription
        }

        print("   Found \(parameterSets.count) parameter set(s)")

        var formatDesc: CMFormatDescription?

        // Call the Core Media API with proper pointer lifetime
        let status = createH264FormatDescriptionFromParameterSets(
            parameterSets: parameterSets,
            formatDescriptionOut: &formatDesc
        )

        guard status == noErr, let formatDesc = formatDesc else {
            print("❌ CMVideoFormatDescriptionCreateFromH264ParameterSets failed with status: \(status)")
            throw VideoToolboxDecoderError.cannotCreateFormatDescription
        }

        print("   ✅ Successfully created H.264 format description from \(parameterSets.count) parameter sets")
        return formatDesc
    }

    // Helper to create format description with proper pointer lifetime
    private static func createFormatDescriptionFromParameterSets(
        parameterSets: [Data],
        formatDescriptionOut: inout CMFormatDescription?
    ) -> OSStatus {
        // Build arrays we can pass to Core Media
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []

        // Use withUnsafeBytes on each Data to get stable pointers
        for data in parameterSets {
            data.withUnsafeBytes { bytes in
                pointers.append(bytes.baseAddress!.assumingMemoryBound(to: UInt8.self))
                sizes.append(data.count)
            }
        }

        // This won't work because the pointers escape the withUnsafeBytes scope
        // Need a different approach - use contiguous memory

        // Flatten all parameter sets into one contiguous buffer
        let totalSize = parameterSets.reduce(0) { $0 + $1.count }
        var flattenedData = Data(capacity: totalSize)
        for ps in parameterSets {
            flattenedData.append(ps)
        }

        sizes = parameterSets.map { $0.count }

        return flattenedData.withUnsafeBytes { flatBytes in
            var pointers: [UnsafePointer<UInt8>] = []
            var offset = 0

            for size in sizes {
                let ptr = flatBytes.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                pointers.append(ptr)
                offset += size
            }

            return pointers.withUnsafeBufferPointer { ptrBuffer in
                sizes.withUnsafeBufferPointer { sizeBuffer in
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: parameterSets.count,
                        parameterSetPointers: ptrBuffer.baseAddress!,
                        parameterSetSizes: sizeBuffer.baseAddress!,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &formatDescriptionOut
                    )
                }
            }
        }
    }

    // Parse HEVC parameter sets from hvcC format
    private static func parseHEVCParameterSets(from data: Data) throws -> [Data] {
        var parameterSets: [Data] = []
        var offset = 0

        guard data.count > 23 else {
            print("⚠️ Extradata too small for hvcC format, using as-is")
            // Fallback: treat entire data as single parameter set
            return [data]
        }

        // Skip hvcC header (23 bytes minimum)
        // configurationVersion: 1 byte
        // profile/tier/level info: 12 bytes
        // min_spatial_segmentation_idc: 2 bytes
        // parallelismType: 1 byte
        // chromaFormat: 1 byte
        // bitDepthLumaMinus8: 1 byte
        // bitDepthChromaMinus8: 1 byte
        // avgFrameRate: 2 bytes
        // constantFrameRate/numTemporalLayers/temporalIdNested/lengthSizeMinusOne: 1 byte
        // numOfArrays: 1 byte
        offset = 22

        let numOfArrays = data[offset]
        offset += 1

        print("   hvcC numOfArrays: \(numOfArrays)")

        // Parse each array (VPS, SPS, PPS, etc.)
        for arrayIndex in 0..<Int(numOfArrays) {
            guard offset + 3 <= data.count else { break }

            // array_completeness (1 bit) + reserved (1 bit) + NAL_unit_type (6 bits)
            let arrayHeader = data[offset]
            let nalUnitType = arrayHeader & 0x3F
            offset += 1

            // numNalus (2 bytes)
            let numNalus = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            offset += 2

            print("   Array \(arrayIndex): NAL type \(nalUnitType), count \(numNalus)")

            // Read each NAL unit in this array
            for _ in 0..<Int(numNalus) {
                guard offset + 2 <= data.count else { break }

                // nalUnitLength (2 bytes)
                let nalLength = Int(UInt16(data[offset]) << 8 | UInt16(data[offset + 1]))
                offset += 2

                guard offset + nalLength <= data.count else { break }

                // Extract NAL unit
                let nalUnit = data.subdata(in: offset..<(offset + nalLength))
                parameterSets.append(nalUnit)

                print("   - NAL unit: \(nalLength) bytes")

                offset += nalLength
            }
        }

        return parameterSets
    }

    // Helper to create H.264 format description with proper pointer lifetime
    private static func createH264FormatDescriptionFromParameterSets(
        parameterSets: [Data],
        formatDescriptionOut: inout CMFormatDescription?
    ) -> OSStatus {
        // Flatten all parameter sets into one contiguous buffer
        let totalSize = parameterSets.reduce(0) { $0 + $1.count }
        var flattenedData = Data(capacity: totalSize)
        for ps in parameterSets {
            flattenedData.append(ps)
        }

        let sizes = parameterSets.map { $0.count }

        return flattenedData.withUnsafeBytes { flatBytes in
            var pointers: [UnsafePointer<UInt8>] = []
            var offset = 0

            for size in sizes {
                let ptr = flatBytes.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                pointers.append(ptr)
                offset += size
            }

            return pointers.withUnsafeBufferPointer { ptrBuffer in
                sizes.withUnsafeBufferPointer { sizeBuffer in
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: parameterSets.count,
                        parameterSetPointers: ptrBuffer.baseAddress!,
                        parameterSetSizes: sizeBuffer.baseAddress!,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &formatDescriptionOut
                    )
                }
            }
        }
    }

    // Parse H.264 parameter sets from avcC format
    private static func parseH264ParameterSets(from data: Data) throws -> [Data] {
        var parameterSets: [Data] = []
        var offset = 0

        guard data.count > 6 else {
            print("⚠️ Extradata too small for avcC format, using as-is")
            return [data]
        }

        // avcC structure (ISO/IEC 14496-15):
        // configurationVersion: 1 byte
        // AVCProfileIndication: 1 byte
        // profile_compatibility: 1 byte
        // AVCLevelIndication: 1 byte
        // lengthSizeMinusOne: 1 byte (6 bits reserved + 2 bits)
        // numOfSequenceParameterSets: 1 byte (3 bits reserved + 5 bits)
        offset = 5

        // Number of SPS
        let numSPS = Int(data[offset] & 0x1F) // Lower 5 bits
        offset += 1

        print("   avcC numSPS: \(numSPS)")

        // Read SPS
        for _ in 0..<numSPS {
            guard offset + 2 <= data.count else { break }

            let spsLength = Int(UInt16(data[offset]) << 8 | UInt16(data[offset + 1]))
            offset += 2

            guard offset + spsLength <= data.count else { break }

            let sps = data.subdata(in: offset..<(offset + spsLength))
            parameterSets.append(sps)
            print("   - SPS: \(spsLength) bytes")

            offset += spsLength
        }

        // Number of PPS
        guard offset < data.count else { return parameterSets }
        let numPPS = Int(data[offset])
        offset += 1

        print("   avcC numPPS: \(numPPS)")

        // Read PPS
        for _ in 0..<numPPS {
            guard offset + 2 <= data.count else { break }

            let ppsLength = Int(UInt16(data[offset]) << 8 | UInt16(data[offset + 1]))
            offset += 2

            guard offset + ppsLength <= data.count else { break }

            let pps = data.subdata(in: offset..<(offset + ppsLength))
            parameterSets.append(pps)
            print("   - PPS: \(ppsLength) bytes")

            offset += ppsLength
        }

        return parameterSets
    }

    // MARK: - Decompression Session

    private func createDecompressionSession() throws {
        guard let formatDescription = formatDescription else {
            throw VideoToolboxDecoderError.cannotCreateFormatDescription
        }

        // Determine pixel format based on video info
        // For 10-bit content, try FullRange first, then let VideoToolbox auto-select
        let is10Bit = videoInfo.pixelFormat == AV_PIX_FMT_YUV420P10LE ||
                      videoInfo.pixelFormat == AV_PIX_FMT_YUV420P10BE

        // Pixel buffer attributes
        // Note: Not specifying pixel format lets VideoToolbox choose the best supported format
        let pixelBufferAttributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: videoInfo.width,
            kCVPixelBufferHeightKey: videoInfo.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true
        ]

        if is10Bit {
            print("🎨 10-bit HDR content detected - letting VideoToolbox choose pixel format")
        } else {
            print("🎨 8-bit SDR content detected - letting VideoToolbox choose pixel format")
        }

        // Decompression callback
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decompressionCallback,
            decompressionOutputRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil, // nil = use hardware if available
            imageBufferAttributes: pixelBufferAttributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            print("❌ VTDecompressionSessionCreate failed with status: \(status)")
            print("   Format description: \(String(describing: formatDescription))")
            print("   Pixel format: Auto-select (not specified)")
            throw VideoToolboxDecoderError.cannotCreateDecompressionSession
        }

        self.decompressionSession = session

        // Set properties for real-time decoding
        VTSessionSetProperty(
            session,
            key: kVTDecompressionPropertyKey_RealTime,
            value: kCFBooleanTrue
        )
    }

    // MARK: - Decoding

    public func decode(packet: VideoPacket) throws -> [DecodedFrame] {
        guard let decompressionSession = decompressionSession,
              let formatDescription = formatDescription else {
            throw VideoToolboxDecoderError.cannotCreateDecompressionSession
        }

        // Create CMSampleBuffer from VideoPacket
        let sampleBuffer = try createSampleBuffer(
            from: packet,
            formatDescription: formatDescription
        )

        // Clear pending frames before decode
        frameQueue.sync {
            pendingFrames.removeAll()
        }

        // Decode frame
        var flagsOut = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: nil,
            infoFlagsOut: &flagsOut
        )

        guard status == noErr else {
            throw VideoToolboxDecoderError.decodingFailed(status: status)
        }

        // Wait for decode to complete
        VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)

        // Return decoded frames
        return frameQueue.sync {
            let frames = pendingFrames
            pendingFrames.removeAll()
            return frames
        }
    }

    // MARK: - Sample Buffer Creation

    private func createSampleBuffer(
        from packet: VideoPacket,
        formatDescription: CMFormatDescription
    ) throws -> CMSampleBuffer {
        // Create CMBlockBuffer from packet data
        var blockBuffer: CMBlockBuffer?
        let status = packet.data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSStatus in
            return CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: packet.data.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: packet.data.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }

        guard status == noErr, let blockBuffer = blockBuffer else {
            throw VideoToolboxDecoderError.cannotCreateBlockBuffer
        }

        // Copy data to block buffer
        let copyStatus = packet.data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSStatus in
            return CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: packet.data.count
            )
        }

        guard copyStatus == noErr else {
            throw VideoToolboxDecoderError.cannotCreateBlockBuffer
        }

        // Create timing info
        let pts = CMTime(
            value: packet.pts,
            timescale: CMTimeScale(timebase.den)
        )
        let duration = CMTime(
            value: packet.duration,
            timescale: CMTimeScale(timebase.den)
        )
        let dts = CMTime(
            value: packet.dts,
            timescale: CMTimeScale(timebase.den)
        )

        var timingInfo = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: pts,
            decodeTimeStamp: dts
        )

        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sampleBuffer = sampleBuffer else {
            throw VideoToolboxDecoderError.cannotCreateSampleBuffer
        }

        // Attach sync frame flag if keyframe
        if packet.isKeyframe {
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true)
            if let attachments = attachments as? [CFMutableDictionary], let dict = attachments.first {
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanFalse).toOpaque()
                )
            }
        }

        return sampleBuffer
    }

    // MARK: - Callback

    fileprivate func handleDecodedFrame(
        status: OSStatus,
        infoFlags: VTDecodeInfoFlags,
        imageBuffer: CVImageBuffer?,
        presentationTimeStamp: CMTime,
        presentationDuration: CMTime
    ) {
        guard status == noErr else {
            print("⚠️ Decode callback error: \(status)")
            return
        }

        guard let pixelBuffer = imageBuffer else {
            print("⚠️ No pixel buffer in callback")
            return
        }

        // Log pixel format on first frame
        if !hasLoggedPixelFormat {
            hasLoggedPixelFormat = true
            let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            print("🎨 VideoToolbox chose pixel format: \(pixelFormat) (\(width)x\(height))")
        }

        // Attach HDR color space information
        attachColorSpaceInfo(to: pixelBuffer)

        let decodedFrame = DecodedFrame(
            pixelBuffer: pixelBuffer,
            pts: presentationTimeStamp.value,
            duration: presentationDuration.value,
            isKeyFrame: false // Will be set from packet info if needed
        )

        frameQueue.sync {
            pendingFrames.append(decodedFrame)
        }
    }

    // MARK: - Color Space Attachment

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
    }

    private func attachMasteringDisplayMetadata(_ metadata: MasteringDisplayMetadata, to pixelBuffer: CVPixelBuffer) {
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
    }

    public func flush() throws -> [DecodedFrame] {
        // VideoToolbox doesn't have explicit flush like FFmpeg
        // Frames are delivered synchronously after WaitForAsynchronousFrames
        return []
    }

    deinit {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
    }
}

// MARK: - Decompression Callback (C Function)

private func decompressionCallback(
    decompressionOutputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVImageBuffer?,
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime
) {
    guard let decompressionOutputRefCon = decompressionOutputRefCon else {
        return
    }

    let decoder = Unmanaged<VideoToolboxDecoder>.fromOpaque(decompressionOutputRefCon).takeUnretainedValue()
    decoder.handleDecodedFrame(
        status: status,
        infoFlags: infoFlags,
        imageBuffer: imageBuffer,
        presentationTimeStamp: presentationTimeStamp,
        presentationDuration: presentationDuration
    )
}
