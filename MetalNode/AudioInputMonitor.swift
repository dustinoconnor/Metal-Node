//
//  AudioInputMonitor.swift
//  MetalNode
//
//  Created by Codex on 3/13/26.
//

import Accelerate
import AppKit
@preconcurrency import AVFoundation
import Combine
import Foundation
import CoreVideo
import Metal
import Vision

struct HandTrackingSnapshot: Equatable {
    var leftIndex: CGPoint?
    var rightIndex: CGPoint?
    var leftThumb: CGPoint?
    var rightThumb: CGPoint?
    var status = "Idle"
}

@MainActor
final class AudioInputMonitor: ObservableObject {
    struct Snapshot: Equatable {
        var amplitude: Float = 0
        var low: Float = 0
        var mid: Float = 0
        var high: Float = 0
        var deviceName = "Default Input"
        var status = "Idle"
    }

    @Published private(set) var snapshot = Snapshot()

    private let engine = AVAudioEngine()
    private let analysisQueue = DispatchQueue(label: "MetalNode.AudioAnalysis")
    private var cancellables = Set<AnyCancellable>()
    private var healthTimer: Timer?
    private var fftSetup: FFTSetup?
    private let fftSize = 1024
    private let log2n: vDSP_Length = 10
    private var smoothedAmplitude: Float = 0
    private var smoothedLow: Float = 0
    private var smoothedMid: Float = 0
    private var smoothedHigh: Float = 0
    private var amplitudeReference: Float = 0.08
    private var lowReference: Float = 1
    private var midReference: Float = 1
    private var highReference: Float = 1
    private var lastAudioFrameDate = Date.distantPast
    private var isTapInstalled = false
    private var isRestartScheduled = false
    private var isMonitoringEnabled = false

    init() {
        configureObservers()
        startHealthCheck()
    }

    deinit {
        healthTimer?.invalidate()
        cancellables.removeAll()
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        engine.reset()
    }

    func value(for signal: AudioSignalKind) -> Double {
        switch signal {
        case .amplitude:
            return Double(snapshot.amplitude)
        case .low:
            return Double(snapshot.low)
        case .mid:
            return Double(snapshot.mid)
        case .high:
            return Double(snapshot.high)
        }
    }

    func setMonitoringEnabled(_ enabled: Bool) {
        guard enabled != isMonitoringEnabled else { return }
        isMonitoringEnabled = enabled

        if enabled {
            snapshot.status = "Starting"
            start()
        } else {
            isRestartScheduled = false
            teardownEngine()
            snapshot.amplitude = 0
            snapshot.low = 0
            snapshot.mid = 0
            snapshot.high = 0
            snapshot.status = "Inactive"
        }
    }

    func start() {
        guard isMonitoringEnabled else {
            snapshot.status = "Inactive"
            return
        }

        if engine.isRunning && isTapInstalled {
            snapshot.status = "Listening"
            return
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            snapshot.status = "No audio input device available."
            return
        }

        if fftSetup == nil {
            fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        }

        snapshot.deviceName = inputFormat.channelCount > 0 ? "Default Input" : "Unavailable"
        snapshot.status = "Starting"

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftSize), format: inputFormat) { [weak self] buffer, _ in
            self?.analyze(buffer: buffer)
        }
        isTapInstalled = true

        do {
            if engine.isRunning {
                engine.stop()
            }
            engine.prepare()
            try engine.start()
            lastAudioFrameDate = Date()
            snapshot.status = "Listening"
        } catch {
            teardownEngine()
            snapshot.status = "Audio start failed: \(error.localizedDescription)"
        }
    }

    private func configureObservers() {
        NotificationCenter.default.publisher(for: .AVAudioEngineConfigurationChange, object: engine)
            .sink { [weak self] _ in
                self?.scheduleRestart(status: "Audio reconfiguring")
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.snapshot.status = "Sleeping"
                self.teardownEngine()
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleRestart(status: "Waking audio")
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.recoverIfNeeded()
            }
            .store(in: &cancellables)
    }

    private func startHealthCheck() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recoverIfNeeded()
            }
        }
        if let healthTimer {
            RunLoop.main.add(healthTimer, forMode: .common)
        }
    }

    private func recoverIfNeeded() {
        guard isMonitoringEnabled else { return }

        let stalled = Date().timeIntervalSince(lastAudioFrameDate) > 3.0
        if !engine.isRunning || !isTapInstalled || stalled {
            scheduleRestart(status: stalled ? "Recovering audio" : "Restarting audio")
        }
    }

    private func scheduleRestart(status: String) {
        guard isMonitoringEnabled, !isRestartScheduled else { return }
        isRestartScheduled = true
        snapshot.status = status

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.isRestartScheduled = false
            self.teardownEngine()
            self.start()
        }
    }

    private func teardownEngine() {
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        engine.reset()
        lastAudioFrameDate = Date.distantPast
    }

    private func analyze(buffer: AVAudioPCMBuffer) {
        analysisQueue.async { [weak self] in
            guard
                let self,
                let fftSetup = self.fftSetup,
                let channelData = buffer.floatChannelData?.pointee
            else {
                return
            }

            let frameCount = min(Int(buffer.frameLength), self.fftSize)
            if frameCount == 0 {
                return
            }

            var window = [Float](repeating: 0, count: self.fftSize)
            var samples = [Float](repeating: 0, count: self.fftSize)
            samples.replaceSubrange(0..<frameCount, with: UnsafeBufferPointer(start: channelData, count: frameCount))
            vDSP_hann_window(&window, vDSP_Length(self.fftSize), Int32(vDSP_HANN_NORM))
            vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(self.fftSize))

            var rms: Float = 0
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(self.fftSize))

            var real = [Float](repeating: 0, count: self.fftSize / 2)
            var imag = [Float](repeating: 0, count: self.fftSize / 2)

            real.withUnsafeMutableBufferPointer { realBuffer in
                imag.withUnsafeMutableBufferPointer { imagBuffer in
                    var splitComplex = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                    samples.withUnsafeBufferPointer { sampleBuffer in
                        sampleBuffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: self.fftSize / 2) { complexPointer in
                            vDSP_ctoz(complexPointer, 2, &splitComplex, 1, vDSP_Length(self.fftSize / 2))
                        }
                    }
                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, self.log2n, FFTDirection(FFT_FORWARD))
                }
            }

            let magnitudes = zip(real, imag).map { hypot($0.0, $0.1) }
            let lowRaw = Self.averageBand(magnitudes, range: 2..<32)
            let midRaw = Self.averageBand(magnitudes, range: 32..<128)
            let highRaw = Self.averageBand(magnitudes, range: 128..<256)
            let amplitudeRaw = rms

            Task { @MainActor in
                self.lastAudioFrameDate = Date()
                let decay: Float = 0.985
                self.amplitudeReference = max(amplitudeRaw, self.amplitudeReference * decay, 0.03)
                self.lowReference = max(lowRaw, self.lowReference * decay, 0.015)
                self.midReference = max(midRaw, self.midReference * decay, 0.015)
                self.highReference = max(highRaw, self.highReference * decay, 0.015)

                let amplitudeNormalized = min(max(amplitudeRaw / self.amplitudeReference, 0), 1)
                let lowNormalized = min(max(lowRaw / self.lowReference, 0), 1)
                let midNormalized = min(max(midRaw / self.midReference, 0), 1)
                let highNormalized = min(max(highRaw / self.highReference, 0), 1)

                let smoothing: Float = 0.22
                self.smoothedAmplitude += (amplitudeNormalized - self.smoothedAmplitude) * smoothing
                self.smoothedLow += (lowNormalized - self.smoothedLow) * smoothing
                self.smoothedMid += (midNormalized - self.smoothedMid) * smoothing
                self.smoothedHigh += (highNormalized - self.smoothedHigh) * smoothing

                self.snapshot.amplitude = self.smoothedAmplitude
                self.snapshot.low = self.smoothedLow
                self.snapshot.mid = self.smoothedMid
                self.snapshot.high = self.smoothedHigh
                if self.snapshot.status != "Listening" {
                    self.snapshot.status = "Listening"
                }
            }
        }
    }

    nonisolated private static func averageBand(_ magnitudes: [Float], range: Range<Int>) -> Float {
        let clamped = range.clamped(to: magnitudes.indices)
        guard !clamped.isEmpty else { return 0 }
        let values = magnitudes[clamped]
        return values.reduce(0, +) / Float(values.count)
    }
}

final class VideoInputMonitor: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = VideoInputMonitor()

    @Published private(set) var status = "Idle"
    @Published private(set) var deviceName = "Default Camera"
    @Published private(set) var handSnapshot = HandTrackingSnapshot()

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "MetalNode.VideoCapture")
    private let handTrackingQueue = DispatchQueue(label: "MetalNode.HandTracking")
    private let lock = NSLock()
    private let handTrackingLock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?
    private var textureCache: CVMetalTextureCache?
    private var isConfigured = false
    private var videoRequestClients = Set<UUID>()
    private var handTrackingClients = Set<UUID>()
    private var isHandTrackingFramePending = false
    private var captureStateVersion = 0
    private let handPoseRequest = VNDetectHumanHandPoseRequest()
    private var smoothedXByHand: [CGFloat] = [0.6, 0.4]
    private var smoothedYByHand: [CGFloat] = [0.5, 0.5]
    private var smoothedThumbXByHand: [CGFloat] = [0.6, 0.4]
    private var smoothedThumbYByHand: [CGFloat] = [0.5, 0.5]
    private let smoothingFactor: CGFloat = 0.45
    private let confidenceThreshold: Float = 0.5

    override init() {
        super.init()
        handPoseRequest.maximumHandCount = 2
    }

    private var isVideoRequested: Bool {
        !videoRequestClients.isEmpty
    }

    private var isHandTrackingEnabled: Bool {
        !handTrackingClients.isEmpty
    }

    func setVideoRequested(_ requested: Bool, for clientID: UUID) {
        if requested {
            videoRequestClients.insert(clientID)
        } else {
            videoRequestClients.remove(clientID)
        }
        captureStateVersion += 1

        if isVideoRequested || isHandTrackingEnabled {
            requestCameraAccessIfNeeded()
        } else {
            updateCaptureState()
        }
    }

    func setHandTrackingEnabled(_ enabled: Bool, for clientID: UUID) {
        if enabled {
            handTrackingClients.insert(clientID)
        } else {
            handTrackingClients.remove(clientID)
        }
        captureStateVersion += 1

        if isHandTrackingEnabled {
            requestCameraAccessIfNeeded()
        } else {
            handSnapshot = HandTrackingSnapshot(status: "Idle")
            updateCaptureState()
        }
    }

    private func requestCameraAccessIfNeeded() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStartIfNeeded()
        case .notDetermined:
            status = "Requesting camera access"
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.configureAndStartIfNeeded()
                    } else {
                        self.status = "Camera access denied"
                    }
                }
            }
        case .denied, .restricted:
            status = "Camera access denied"
        @unknown default:
            status = "Camera unavailable"
        }
    }

    private func updateCaptureState() {
        let shouldRun = isVideoRequested || isHandTrackingEnabled
        let stateVersion = captureStateVersion
        if !shouldRun {
            status = "Idle"
        } else if isVideoRequested && !isHandTrackingEnabled && status == "Tracking ready" {
            status = "Live"
        }

        if shouldRun {
            configureAndStartIfNeeded()
            return
        }

        if session.isRunning {
            captureQueue.async { [weak self] in
                guard let self, stateVersion == self.captureStateVersion else { return }
                self.session.stopRunning()
                self.session.beginConfiguration()
                self.session.inputs.forEach { self.session.removeInput($0) }
                self.session.outputs.forEach { self.session.removeOutput($0) }
                self.session.commitConfiguration()
                self.output.setSampleBufferDelegate(nil, queue: nil)
                self.isConfigured = false
            }
        } else {
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            session.commitConfiguration()
            output.setSampleBufferDelegate(nil, queue: nil)
            isConfigured = false
        }

        lock.lock()
        latestPixelBuffer = nil
        lock.unlock()
        handTrackingLock.lock()
        isHandTrackingFramePending = false
        handTrackingLock.unlock()
        if let textureCache {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
        handSnapshot = HandTrackingSnapshot(status: "Idle")
    }

    func makeTexture(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm) -> MTLTexture? {
        lock.lock()
        let pixelBuffer = latestPixelBuffer
        lock.unlock()

        guard let pixelBuffer else { return nil }

        if textureCache == nil {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        }

        guard let textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            0,
            &cvTexture
        )

        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }

        return texture
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        latestPixelBuffer = imageBuffer
        lock.unlock()

        guard isHandTrackingEnabled else { return }

        handTrackingLock.lock()
        let shouldProcessFrame = !isHandTrackingFramePending
        if shouldProcessFrame {
            isHandTrackingFramePending = true
        }
        handTrackingLock.unlock()

        guard shouldProcessFrame else { return }

        handTrackingQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.handTrackingLock.lock()
                self.isHandTrackingFramePending = false
                self.handTrackingLock.unlock()
            }

            self.processHandTrackingFrame(imageBuffer)
        }
    }

    private func processHandTrackingFrame(_ imageBuffer: CVPixelBuffer) {
        let handler = VNImageRequestHandler(cvPixelBuffer: imageBuffer, options: [:])
        do {
            try handler.perform([handPoseRequest])
            let observations = handPoseRequest.results ?? []
            struct DetectedHand {
                let index: CGPoint
                let thumb: CGPoint?
            }
            var detectedHands: [DetectedHand] = []

            for observation in observations.prefix(2) {
                guard let tip = try? observation.recognizedPoint(.indexTip),
                      tip.confidence > confidenceThreshold else {
                    continue
                }

                let thumbTip = try? observation.recognizedPoint(.thumbTip)

                let rawX = tip.location.x
                let rawY = 1 - tip.location.y
                let thumbPoint: CGPoint?
                if let thumbTip, thumbTip.confidence > confidenceThreshold {
                    thumbPoint = CGPoint(x: thumbTip.location.x, y: 1 - thumbTip.location.y)
                } else {
                    thumbPoint = nil
                }

                detectedHands.append(
                    DetectedHand(
                        index: CGPoint(x: rawX, y: rawY),
                        thumb: thumbPoint
                    )
                )
            }

            detectedHands.sort { $0.index.x < $1.index.x }

            var left: CGPoint?
            var right: CGPoint?
            var leftThumb: CGPoint?
            var rightThumb: CGPoint?

            for handIndex in 0..<2 {
                guard handIndex < detectedHands.count else { continue }
                let rawHand = detectedHands[handIndex]
                let rawPoint = rawHand.index
                let extra = max(0, 0.3 - smoothedYByHand[handIndex]) / 0.3
                let localSmoothing = min(1.0, smoothingFactor + extra * 0.15)
                smoothedXByHand[handIndex] += (rawPoint.x - smoothedXByHand[handIndex]) * localSmoothing
                smoothedYByHand[handIndex] += (rawPoint.y - smoothedYByHand[handIndex]) * localSmoothing
                let smoothed = CGPoint(x: smoothedXByHand[handIndex], y: smoothedYByHand[handIndex])

                let smoothedThumb: CGPoint?
                if let rawThumb = rawHand.thumb {
                    smoothedThumbXByHand[handIndex] += (rawThumb.x - smoothedThumbXByHand[handIndex]) * localSmoothing
                    smoothedThumbYByHand[handIndex] += (rawThumb.y - smoothedThumbYByHand[handIndex]) * localSmoothing
                    smoothedThumb = CGPoint(x: smoothedThumbXByHand[handIndex], y: smoothedThumbYByHand[handIndex])
                } else {
                    smoothedThumb = nil
                }

                if handIndex == 0 {
                    left = smoothed
                    leftThumb = smoothedThumb
                } else {
                    right = smoothed
                    rightThumb = smoothedThumb
                }
            }

            DispatchQueue.main.async { [weak self] in
                self?.handSnapshot = HandTrackingSnapshot(
                    leftIndex: left,
                    rightIndex: right,
                    leftThumb: leftThumb,
                    rightThumb: rightThumb,
                    status: detectedHands.isEmpty ? "No hands" : "Tracking"
                )
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.handSnapshot = HandTrackingSnapshot(status: "Vision error")
            }
        }
    }

    private func configureAndStartIfNeeded() {
        guard isVideoRequested || isHandTrackingEnabled else { return }
        guard !isConfigured else {
            let stateVersion = captureStateVersion
            if !session.isRunning {
                captureQueue.async { [weak self] in
                    guard let self, stateVersion == self.captureStateVersion else { return }
                    guard self.isVideoRequested || self.isHandTrackingEnabled else { return }
                    self.session.startRunning()
                }
            }
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .medium

        defer {
            session.commitConfiguration()
            isConfigured = true
            let stateVersion = captureStateVersion
            captureQueue.async { [weak self] in
                guard let self, stateVersion == self.captureStateVersion else { return }
                guard self.isVideoRequested || self.isHandTrackingEnabled else { return }
                self.session.startRunning()
            }
            status = isHandTrackingEnabled ? "Tracking ready" : "Live"
        }

        guard let device = AVCaptureDevice.default(for: .video) else {
            status = "No camera available"
            return
        }

        deviceName = device.localizedName

        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            status = "Camera input failed"
            return
        }
        session.addInput(input)

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)

        guard session.canAddOutput(output) else {
            status = "Camera output failed"
            return
        }
        session.addOutput(output)

        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.isVideoMirrored = true
        }
    }
}
