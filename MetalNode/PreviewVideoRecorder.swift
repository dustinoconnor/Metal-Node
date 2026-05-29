import AVFoundation
import CoreImage
@preconcurrency import Metal

final class PreviewVideoRecorder {
    private struct AudioChunk {
        let data: Data
        let frameCount: Int
        let sampleRate: Double
        let channelCount: Int

        func trimmed(toFrameCount requestedFrameCount: Int) -> AudioChunk {
            let clampedFrameCount = max(0, min(frameCount, requestedFrameCount))
            let bytesPerFrame = channelCount * MemoryLayout<Float>.size
            let byteCount = clampedFrameCount * bytesPerFrame
            return AudioChunk(
                data: data.prefix(byteCount),
                frameCount: clampedFrameCount,
                sampleRate: sampleRate,
                channelCount: channelCount
            )
        }
    }

    private let outputURL: URL
    private let duration: Double
    private let fps: Int32
    private let maxFrames: Int64
    private let requestedWidth: Int?
    private let requestedHeight: Int?
    private let audioSampleRate: Double?
    private let audioChannelCount: Int?
    private let completion: (Result<URL, Error>) -> Void
    private let progress: (String) -> Void
    private let queue = DispatchQueue(label: "com.dust.metalcomposer.preview-video-recorder")
    private let ciContext = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])
    private let frameGateLock = NSLock()

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var frameIndex: Int64 = 0
    private var audioFramePosition: Int64 = 0
    private var recordingStartTime: TimeInterval?
    private var lastFrameReservationTime: TimeInterval?
    private var isFinishing = false
    private var didFail = false

    init(
        outputURL: URL,
        duration: Double,
        fps: Int32 = 60,
        width: Int? = nil,
        height: Int? = nil,
        audioFormat: AVAudioFormat? = nil,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        self.outputURL = outputURL
        self.duration = max(0.1, duration)
        self.fps = max(1, fps)
        self.maxFrames = max(1, Int64((duration * Double(max(1, fps))).rounded()))
        self.requestedWidth = width
        self.requestedHeight = height
        self.audioSampleRate = audioFormat?.sampleRate
        self.audioChannelCount = audioFormat.map { max(1, min(Int($0.channelCount), 2)) }
        self.progress = progress
        self.completion = completion
        progress("Recording 0%")
    }

    func reserveVideoFramePresentationTime(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval? {
        frameGateLock.lock()
        defer { frameGateLock.unlock() }

        let startTime = recordingStartTime ?? uptime
        recordingStartTime = startTime
        let elapsed = uptime - startTime
        guard elapsed < duration else {
            finish()
            return nil
        }

        let frameInterval = 1.0 / Double(max(fps, 1))
        if let lastFrameReservationTime,
           uptime - lastFrameReservationTime < frameInterval * 0.9 {
            return nil
        }

        lastFrameReservationTime = uptime
        return elapsed
    }

    func capture(texture: MTLTexture, displaySize: CGSize, presentationTime: TimeInterval) {
        queue.async { [weak self] in
            guard let self, !self.isFinishing, !self.didFail else { return }
            guard presentationTime < self.duration, self.frameIndex < self.maxFrames else {
                self.finishOnQueue()
                return
            }
            do {
                let didAppendFrame = try self.appendFrame(
                    texture: texture,
                    displaySize: displaySize,
                    presentationTime: presentationTime,
                    outputURL: self.outputURL
                )
                guard didAppendFrame else { return }

                self.frameIndex += 1
                let elapsedProgress = min(max(presentationTime / self.duration, 0.0), 1.0)
                let frameProgress = Double(self.frameIndex) / Double(self.maxFrames)
                let percent = Int(max(elapsedProgress, frameProgress) * 100.0)
                DispatchQueue.main.async {
                    self.progress("Recording \(percent)%")
                }
            } catch {
                self.didFail = true
                DispatchQueue.main.async {
                    self.progress("Export failed: \(error.localizedDescription)")
                    self.completion(.failure(error))
                }
            }
        }
    }

    func captureAudio(buffer: AVAudioPCMBuffer) {
        guard let chunk = Self.makeAudioChunk(from: buffer, preferredChannelCount: audioChannelCount) else { return }
        queue.async { [weak self] in
            self?.appendAudioChunk(chunk)
        }
    }

    func finish() {
        queue.async { [weak self] in
            self?.finishOnQueue()
        }
    }

    private func finishOnQueue() {
        guard !isFinishing else { return }
        isFinishing = true
        DispatchQueue.main.async {
            self.progress("Finishing export...")
        }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writer?.finishWriting {
            let error = self.writer?.error
            DispatchQueue.main.async {
                if let error {
                    self.progress("Export failed: \(error.localizedDescription)")
                    self.completion(.failure(error))
                } else {
                    self.progress("Saved \(self.outputURL.lastPathComponent)")
                    self.completion(.success(self.outputURL))
                }
            }
        }
    }

    private func appendFrame(texture: MTLTexture, displaySize: CGSize, presentationTime: TimeInterval, outputURL: URL) throws -> Bool {
        let outputWidth = evenDimension(requestedWidth ?? Int(displaySize.width.rounded()))
        let outputHeight = evenDimension(requestedHeight ?? Int(displaySize.height.rounded()))
        try ensureWriter(width: outputWidth, height: outputHeight, outputURL: outputURL)
        guard let writer, let videoInput, let adaptor else { return false }
        guard writer.status != .failed else {
            throw writer.error ?? NSError(domain: "PreviewVideoRecorder", code: 1)
        }
        guard videoInput.isReadyForMoreMediaData else { return false }
        guard let pool = adaptor.pixelBufferPool else { return false }

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pixelBuffer else { return false }

        guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: CGColorSpaceCreateDeviceRGB()]) else {
            return false
        }
        let flippedImage = image
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
            .transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(texture.height)))
            .transformed(by: CGAffineTransform(
                scaleX: CGFloat(outputWidth) / CGFloat(max(texture.width, 1)),
                y: CGFloat(outputHeight) / CGFloat(max(texture.height, 1))
            ))

        ciContext.render(
            flippedImage,
            to: pixelBuffer,
            bounds: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let time = CMTime(seconds: presentationTime, preferredTimescale: 600)
        return adaptor.append(pixelBuffer, withPresentationTime: time)
    }

    private func appendAudioChunk(_ chunk: AudioChunk) {
        guard let writer, let audioInput, writer.status == .writing, !isFinishing, !didFail else { return }
        guard audioInput.isReadyForMoreMediaData else { return }

        let maxAudioFrames = Int64((duration * chunk.sampleRate).rounded())
        let remainingFrames = maxAudioFrames - audioFramePosition
        guard remainingFrames > 0 else { return }

        let chunkToAppend: AudioChunk
        if Int64(chunk.frameCount) > remainingFrames {
            chunkToAppend = chunk.trimmed(toFrameCount: Int(remainingFrames))
        } else {
            chunkToAppend = chunk
        }

        guard let sampleBuffer = Self.makeSampleBuffer(from: chunkToAppend, startingFrame: audioFramePosition) else { return }

        if !audioInput.append(sampleBuffer) {
            didFail = true
            let error = writer.error ?? NSError(domain: "PreviewVideoRecorder", code: 3)
            DispatchQueue.main.async {
                self.progress("Export failed: \(error.localizedDescription)")
                self.completion(.failure(error))
            }
            return
        }

        audioFramePosition += Int64(chunkToAppend.frameCount)
    }

    private func ensureWriter(width: Int, height: Int, outputURL: URL) throws {
        if writer != nil { return }

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let bitRate = max(width * height * 16, 8_000_000)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: attributes)

        guard writer.canAdd(videoInput) else {
            throw NSError(domain: "PreviewVideoRecorder", code: 2)
        }
        writer.add(videoInput)

        if let audioSampleRate, let audioChannelCount {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audioSampleRate,
                AVNumberOfChannelsKey: audioChannelCount,
                AVEncoderBitRateKey: 192_000
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true
            if writer.canAdd(audioInput) {
                writer.add(audioInput)
                self.audioInput = audioInput
            }
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.videoInput = videoInput
        self.adaptor = adaptor
    }

    private func evenDimension(_ value: Int) -> Int {
        let clamped = max(value, 2)
        return clamped.isMultiple(of: 2) ? clamped : clamped + 1
    }

    private static func makeAudioChunk(from buffer: AVAudioPCMBuffer, preferredChannelCount: Int?) -> AudioChunk? {
        guard let channelData = buffer.floatChannelData else { return nil }

        let sourceChannelCount = max(1, Int(buffer.format.channelCount))
        let outputChannelCount = preferredChannelCount ?? min(sourceChannelCount, 2)
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }

        var samples = [Float](repeating: 0, count: frameCount * outputChannelCount)
        if buffer.format.isInterleaved {
            let source = channelData[0]
            for frame in 0..<frameCount {
                for channel in 0..<outputChannelCount {
                    let sourceChannel = min(channel, sourceChannelCount - 1)
                    samples[frame * outputChannelCount + channel] = source[frame * sourceChannelCount + sourceChannel]
                }
            }
        } else {
            for frame in 0..<frameCount {
                for channel in 0..<outputChannelCount {
                    let sourceChannel = min(channel, sourceChannelCount - 1)
                    samples[frame * outputChannelCount + channel] = channelData[sourceChannel][frame]
                }
            }
        }

        let data = samples.withUnsafeBufferPointer { pointer in
            Data(buffer: pointer)
        }
        return AudioChunk(
            data: data,
            frameCount: frameCount,
            sampleRate: buffer.format.sampleRate,
            channelCount: outputChannelCount
        )
    }

    private static func makeSampleBuffer(from chunk: AudioChunk, startingFrame: Int64) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: chunk.data.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: chunk.data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let replaceStatus = chunk.data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: chunk.data.count
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else { return nil }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: chunk.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(chunk.channelCount * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(chunk.channelCount * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(chunk.channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(chunk.sampleRate.rounded())),
            presentationTimeStamp: CMTime(value: startingFrame, timescale: CMTimeScale(chunk.sampleRate.rounded())),
            decodeTimeStamp: .invalid
        )
        var sampleSize = chunk.channelCount * MemoryLayout<Float>.size
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: chunk.frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr else { return nil }
        return sampleBuffer
    }
}
