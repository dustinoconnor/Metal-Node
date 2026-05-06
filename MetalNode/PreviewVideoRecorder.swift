import AVFoundation
import CoreImage
@preconcurrency import Metal

final class PreviewVideoRecorder {
    private let outputURL: URL
    private let fps: Int32
    private let maxFrames: Int64
    private let requestedWidth: Int?
    private let requestedHeight: Int?
    private let completion: (Result<URL, Error>) -> Void
    private let progress: (String) -> Void
    private let queue = DispatchQueue(label: "com.dust.metalcomposer.preview-video-recorder")
    private let ciContext = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var frameIndex: Int64 = 0
    private var isFinishing = false
    private var didFail = false

    init(
        outputURL: URL,
        duration: Double,
        fps: Int32 = 60,
        width: Int? = nil,
        height: Int? = nil,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        self.outputURL = outputURL
        self.fps = max(1, fps)
        self.maxFrames = max(1, Int64((duration * Double(max(1, fps))).rounded()))
        self.requestedWidth = width
        self.requestedHeight = height
        self.progress = progress
        self.completion = completion
        progress("Recording 0%")
    }

    func capture(texture: MTLTexture, displaySize: CGSize) {
        queue.async { [weak self] in
            guard let self, !self.isFinishing, !self.didFail else { return }
            guard self.frameIndex < self.maxFrames else {
                self.finishOnQueue()
                return
            }
            let frameNumber = self.frameIndex
            self.frameIndex += 1
            let shouldFinish = self.frameIndex >= self.maxFrames
            let percent = Int((Double(self.frameIndex) / Double(self.maxFrames)) * 100.0)
            DispatchQueue.main.async {
                self.progress("Recording \(percent)%")
            }

            do {
                try self.appendFrame(texture: texture, displaySize: displaySize, frameNumber: frameNumber, fps: self.fps, outputURL: self.outputURL)
            } catch {
                self.didFail = true
                DispatchQueue.main.async {
                    self.progress("Export failed: \(error.localizedDescription)")
                    self.completion(.failure(error))
                }
            }

            if shouldFinish {
                self.finishOnQueue()
            }
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

        input?.markAsFinished()
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

    private func appendFrame(texture: MTLTexture, displaySize: CGSize, frameNumber: Int64, fps: Int32, outputURL: URL) throws {
        let outputWidth = evenDimension(requestedWidth ?? Int(displaySize.width.rounded()))
        let outputHeight = evenDimension(requestedHeight ?? Int(displaySize.height.rounded()))
        try ensureWriter(width: outputWidth, height: outputHeight, outputURL: outputURL)
        guard let writer, let input, let adaptor else { return }
        guard writer.status != .failed else {
            throw writer.error ?? NSError(domain: "PreviewVideoRecorder", code: 1)
        }
        guard input.isReadyForMoreMediaData else { return }
        guard let pool = adaptor.pixelBufferPool else { return }

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pixelBuffer else { return }

        guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: CGColorSpaceCreateDeviceRGB()]) else {
            return
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

        let time = CMTime(value: frameNumber, timescale: fps)
        adaptor.append(pixelBuffer, withPresentationTime: time)
    }

    private func ensureWriter(width: Int, height: Int, outputURL: URL) throws {
        if writer != nil { return }

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let bitRate = max(width * height * 16, 8_000_000)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)

        guard writer.canAdd(input) else {
            throw NSError(domain: "PreviewVideoRecorder", code: 2)
        }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
    }

    private func evenDimension(_ value: Int) -> Int {
        let clamped = max(value, 2)
        return clamped.isMultiple(of: 2) ? clamped : clamped + 1
    }
}
