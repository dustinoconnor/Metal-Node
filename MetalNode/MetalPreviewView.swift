//
//  MetalPreviewView.swift
//  MetalNode
//
//  Created by Codex on 3/11/26.
//

import Metal
import MetalKit
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import QuartzCore
import SceneKit
import SwiftUI
import simd

struct MetalPreviewView: NSViewRepresentable {
    let configuration: PreviewRenderConfiguration
    let isRunning: Bool
    var videoRecorder: PreviewVideoRecorder? = nil
    var onMouseChange: ((CGPoint?) -> Void)? = nil
    var onMouseButtonChange: ((Bool, Bool) -> Void)? = nil
    var onModifierFlagsChange: ((NSEvent.ModifierFlags) -> Void)? = nil
    var onScrollChange: ((CGPoint) -> Void)? = nil

    private static let maxFloatUniforms = 32
    private static let maxColorUniforms = 16
    private static let maxPointUniforms = 16
    private static let maxPoint3Uniforms = 16
    private static let maxPoint4Uniforms = 16
    private static let maxBoolUniforms = 16

    func makeCoordinator() -> Coordinator {
        Coordinator(configuration: configuration, isRunning: isRunning, videoRecorder: videoRecorder)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = TrackingMTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.delegate = context.coordinator
        view.onMouseChange = onMouseChange
        view.onMouseButtonChange = onMouseButtonChange
        view.onModifierFlagsChange = onModifierFlagsChange
        view.onScrollChange = onScrollChange
        context.coordinator.configure(view: view)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        if let trackingView = nsView as? TrackingMTKView {
            trackingView.onMouseChange = onMouseChange
            trackingView.onMouseButtonChange = onMouseButtonChange
            trackingView.onModifierFlagsChange = onModifierFlagsChange
            trackingView.onScrollChange = onScrollChange
        }
        context.coordinator.update(configuration: configuration, isRunning: isRunning, videoRecorder: videoRecorder, view: nsView)
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        private struct Scene3DMaterialTextures {
            let diffuse: MTLTexture?
            let specular: MTLTexture?
            let metallic: MTLTexture?
            let bump: MTLTexture?
            let displacement: MTLTexture?
        }

        private struct GaussianSplatVertexGPU {
            var position: SIMD4<Float>
            var color: SIMD4<Float>
            var scale: SIMD4<Float>
            var rotation: SIMD4<Float>
        }

        private struct GaussianSplatUniformsGPU {
            var resolution: SIMD2<Float>
            var position: SIMD3<Float>
            var scale: Float
            var rotationRadians: SIMD3<Float>
            var cameraDistance: Float
            var cameraOrbitRadians: Float
            var cameraPitchRadians: Float
            var cameraPan: SIMD2<Float>
            var pointSize: Float
            var opacity: Float
            var explode: Float
            var chaos: Float
            var particleSpeed: Float
            var particleGravity: Float
            var particleTurbulence: Float
            var particleBoundary: Float
            var time: Float
            var isPanorama: Float
        }

        private struct GaussianSplatBufferCache {
            var assetSignature: String
            var sortSignature: String
            var vertices: [GaussianSplatVertexGPU]
            var buffer: MTLBuffer
            var count: Int
        }

        private let device: MTLDevice?
        private let commandQueue: MTLCommandQueue?
        private let samplerState: MTLSamplerState?
        private weak var view: MTKView?
        private var redrawTimer: Timer?
        private var startTime = CACurrentMediaTime()
        private var liveIsRunning: Bool
        private var frozenRenderTime: Float = 0
        private weak var liveVideoRecorder: PreviewVideoRecorder?

        private var liveConfiguration: PreviewRenderConfiguration
        private var compiledSignature = ""
        private var primaryPipelineState: MTLRenderPipelineState?
        private var secondaryPipelineState: MTLRenderPipelineState?
        private var compositePipelineState: MTLRenderPipelineState?
        private var transformPipelineState: MTLRenderPipelineState?
        private var linePipelineState: MTLRenderPipelineState?
        private var transitionPipelineState: MTLRenderPipelineState?
        private var layerCompositePipelineState: MTLRenderPipelineState?
        private var feedbackPipelineState: MTLRenderPipelineState?
        private var trailPipelineState: MTLRenderPipelineState?
        private var circlePipelineState: MTLRenderPipelineState?
        private var videoPipelineState: MTLRenderPipelineState?
        private var underwaterPipelineState: MTLRenderPipelineState?
        private var coreImageEffectPipelineState: MTLRenderPipelineState?
        private var gaussianSplatPipelineState: MTLRenderPipelineState?
        private var trailHistory: [TrailHistoryPoint] = []
        private var lastTrailAppendTime: Float = 0
        private var feedbackHistoryTextures: [UUID: MTLTexture] = [:]
        private var renderTexturePool: [String: [MTLTexture]] = [:]
        private var renderTexturePoolIndices: [String: Int] = [:]
        private var frameScene3DRenderTextures: [String: MTLTexture] = [:]
        private var imageTextures: [UUID: (fingerprint: Int, texture: MTLTexture)] = [:]
        private var videoTextureCache: CVMetalTextureCache?
        private var sceneRenderers: [UUID: SCNRenderer] = [:]
        private var modelScenes: [UUID: SCNScene] = [:]
        private var modelSceneAssetSignatures: [UUID: Int] = [:]
        private var particleScenes: [UUID: SCNScene] = [:]
        private var particleSceneSignatures: [UUID: String] = [:]
        private var sceneParticleNodes: [UUID: (signature: String, node: SCNNode)] = [:]
        private var scene3DRenderScenes: [UUID: SCNScene] = [:]
        private var scene3DRenderSceneSignatures: [UUID: String] = [:]
        private static var gaussianSplatBuffers: [UUID: GaussianSplatBufferCache] = [:]
        private static var gaussianSplatLoadJobs: [UUID: String] = [:]
        private var animationPlayerBaseDurations: [ObjectIdentifier: TimeInterval] = [:]
        private var fallbackAnimationBaseDurations: [ObjectIdentifier: TimeInterval] = [:]
        private var loggedModelLoadFailures: Set<String> = []
        private var loggedShaderCompileFailures: Set<Int> = []

        init(configuration: PreviewRenderConfiguration, isRunning: Bool, videoRecorder: PreviewVideoRecorder?) {
            device = MTLCreateSystemDefaultDevice()
            commandQueue = device?.makeCommandQueue()
            liveConfiguration = configuration
            liveIsRunning = isRunning
            liveVideoRecorder = videoRecorder
            if let device {
                let descriptor = MTLSamplerDescriptor()
                descriptor.minFilter = .linear
                descriptor.magFilter = .linear
                descriptor.sAddressMode = .clampToEdge
                descriptor.tAddressMode = .clampToEdge
                samplerState = device.makeSamplerState(descriptor: descriptor)
                CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &videoTextureCache)
            } else {
                samplerState = nil
                videoTextureCache = nil
            }
        }

        func configure(view: MTKView) {
            self.view = view
            compilePipelines(for: view, configuration: liveConfiguration)
            startRedrawLoop()
        }

        func update(configuration: PreviewRenderConfiguration, isRunning: Bool, videoRecorder: PreviewVideoRecorder?, view: MTKView) {
            self.view = view
            liveConfiguration = configuration
            liveVideoRecorder = videoRecorder
            if liveIsRunning != isRunning {
                if isRunning {
                    startTime = CACurrentMediaTime() - CFTimeInterval(frozenRenderTime)
                } else {
                    frozenRenderTime = Float(CACurrentMediaTime() - startTime)
                }
                liveIsRunning = isRunning
            }
            let newSignature = signature(for: configuration)
            if newSignature != compiledSignature {
                sceneRenderers.values.forEach { $0.scene = nil }
                sceneRenderers.removeAll()
                modelScenes.removeAll()
                modelSceneAssetSignatures.removeAll()
                particleScenes.removeAll()
                particleSceneSignatures.removeAll()
                compilePipelines(for: view, configuration: configuration)
            }
            view.draw()
        }

        private func currentRenderTime() -> Float {
            guard liveIsRunning else { return frozenRenderTime }
            return Float(CACurrentMediaTime() - startTime)
        }

        deinit {
            redrawTimer?.invalidate()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard
                let commandQueue,
                let commandBuffer = commandQueue.makeCommandBuffer(),
                let drawable = view.currentDrawable,
                let renderPassDescriptor = view.currentRenderPassDescriptor
            else {
                return
            }

            renderTexturePoolIndices.removeAll(keepingCapacity: true)
            frameScene3DRenderTextures.removeAll(keepingCapacity: true)

            switch liveConfiguration {
            case .empty:
                break
            case .single(let pass):
                guard let primaryPipelineState else { return }
                encodeShaderPass(
                    pass,
                    with: primaryPipelineState,
                    into: renderPassDescriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: view.drawableSize
                )
            case .mix(let primary, let secondary, let amount):
                guard
                    let primaryTexture = makeRenderTexture(for: view),
                    let secondaryTexture = makeRenderTexture(for: view)
                else {
                    return
                }

                renderPassSource(
                    primary,
                    into: primaryTexture,
                    commandBuffer: commandBuffer,
                    drawableSize: view.drawableSize,
                    currentTime: currentRenderTime(),
                    role: .primary
                )

                renderPassSource(
                    secondary,
                    into: secondaryTexture,
                    commandBuffer: commandBuffer,
                    drawableSize: view.drawableSize,
                    currentTime: currentRenderTime(),
                    role: .secondary
                )

                encodeCompositePass(
                    into: renderPassDescriptor,
                    commandBuffer: commandBuffer,
                    primaryTexture: primaryTexture,
                    secondaryTexture: secondaryTexture,
                    amount: amount
                )
            case .transform(let pass):
                encodeTransformPass(
                    pass,
                    into: renderPassDescriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: view.drawableSize,
                    currentTime: currentRenderTime()
                )
            case .lineBatch(let pass):
                encodeLineBatchPass(
                    pass,
                    into: renderPassDescriptor,
                    commandBuffer: commandBuffer
                )
            case .scene3DPrimitive(let pass):
                encodeScene3DPrimitivePass(
                    pass,
                    into: renderPassDescriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: view.drawableSize,
                    currentTime: currentRenderTime()
                )
            case .scene3DText(let pass):
                encodeScene3DTextPass(
                    pass,
                    into: renderPassDescriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: view.drawableSize,
                    currentTime: currentRenderTime()
                )
            case .scene3DModel(let pass):
                encodeScene3DModelPass(
                    pass,
                    into: renderPassDescriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: view.drawableSize,
                    currentTime: currentRenderTime()
                )
            case .scene3DGaussianSplat(let pass):
                encodeScene3DGaussianSplatPass(
                    pass,
                    into: renderPassDescriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: view.drawableSize,
                    currentTime: currentRenderTime()
                )
            case .scene3DParticle(let pass):
                encodeScene3DParticlePass(
                    pass,
                    into: renderPassDescriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: view.drawableSize,
                    currentTime: currentRenderTime()
                )
            case .scene3DRender(let pass):
                encodeScene3DRenderPass(
                    pass,
                    into: renderPassDescriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: view.drawableSize,
                    currentTime: currentRenderTime()
                )
            case .transition(let pass):
                encodeTransitionPass(
                    pass,
                    into: renderPassDescriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: view.drawableSize,
                    currentTime: currentRenderTime()
                )
            case .trail(let pass):
                guard let trailPipelineState else { return }
                encodeTrailPass(
                    pass,
                    with: trailPipelineState,
                    into: renderPassDescriptor,
                    commandBuffer: commandBuffer,
                    currentTime: currentRenderTime()
                )
            case .circle(let pass):
                guard let circlePipelineState else { return }
                encodeCirclePass(
                    pass,
                    with: circlePipelineState,
                    into: renderPassDescriptor,
                    commandBuffer: commandBuffer
                )
            case .clear(let pass):
                encodeClearPass(
                    color: pass.color,
                    into: renderPassDescriptor,
                    commandBuffer: commandBuffer
                )
            case .image(let pass):
                guard let videoPipelineState else { return }
                encodeImagePass(
                    pass,
                    with: videoPipelineState,
                    into: renderPassDescriptor,
                    commandBuffer: commandBuffer
                )
            case .videoPlayer(let pass):
                guard let videoPipelineState else { return }
                encodeVideoPlayerPass(
                    pass,
                    with: videoPipelineState,
                    into: renderPassDescriptor,
                    commandBuffer: commandBuffer
                )
            case .video:
                guard let videoPipelineState else { return }
                encodeVideoPass(
                    with: videoPipelineState,
                    into: renderPassDescriptor,
                    commandBuffer: commandBuffer
                )
            case .coreImage(let pass):
                encodeCoreImagePass(
                    pass,
                    into: renderPassDescriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: view.drawableSize,
                    currentTime: currentRenderTime()
                )
            case .underwater(let pass):
                encodeUnderwaterPass(
                    pass,
                    into: renderPassDescriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: view.drawableSize,
                    currentTime: currentRenderTime()
                )
            case .feedback(let pass):
                encodeFeedbackPass(
                    pass,
                    into: renderPassDescriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: view.drawableSize,
                    currentTime: currentRenderTime()
                )
            case .layers(let layers, let opacity):
                guard let displayPipelineState = videoPipelineState else {
                    return
                }

                let connectedLayers = layers
                guard connectedLayers.isEmpty == false else { return }

                guard
                    let clearTexture = makeRenderTexture(for: view),
                    let overlayTexture = makeRenderTexture(for: view),
                    let compositeTexture = makeRenderTexture(for: view)
                else {
                    return
                }

                var currentBaseTexture = clearTexture
                var scratchTexture = compositeTexture

                clearRenderTexture(
                    currentBaseTexture,
                    color: SIMD4<Float>(0, 0, 0, 0),
                    commandBuffer: commandBuffer
                )

                for (index, layer) in connectedLayers.enumerated() {
                    clearRenderTexture(
                        overlayTexture,
                        color: SIMD4<Float>(0, 0, 0, 0),
                        commandBuffer: commandBuffer
                    )
                    renderPassSource(
                        layer.source,
                        into: overlayTexture,
                        commandBuffer: commandBuffer,
                        drawableSize: view.drawableSize,
                        currentTime: currentRenderTime(),
                        role: index.isMultiple(of: 2) ? .secondary : .primary
                    )
                    encodeLayerCompositePass(
                        into: scratchTexture,
                        commandBuffer: commandBuffer,
                        backgroundTexture: currentBaseTexture,
                        foregroundTexture: overlayTexture,
                        opacity: opacity * layer.opacity
                    )
                    swap(&currentBaseTexture, &scratchTexture)
                }

                encodeTextureDisplayPass(
                    texture: currentBaseTexture,
                    with: displayPipelineState,
                    into: renderPassDescriptor,
                    commandBuffer: commandBuffer
                )
            }

            commandBuffer.present(drawable)
            if let liveVideoRecorder {
                liveVideoRecorder.capture(texture: drawable.texture, displaySize: view.bounds.size)
            }
            commandBuffer.commit()
        }

        private func encodeShaderPass(
            _ pass: PreviewShaderPass,
            with pipelineState: MTLRenderPipelineState,
            into descriptor: MTLRenderPassDescriptor,
            commandBuffer: MTLCommandBuffer,
            drawableSize: CGSize
        ) {
            guard let view else { return }

            var imageUniformTextures: [MTLTexture] = []
            let imageUniformCount = max(
                pass.imageUniformSources.count,
                pass.uniforms.filter { $0.kind == .image }.count,
                declaredResourceBindingCount(in: pass.metalSource, attribute: "texture"),
                declaredResourceBindingCount(in: pass.metalSource, attribute: "sampler")
            )
            if imageUniformCount > 0 {
                for index in 0..<imageUniformCount {
                    guard let texture = makeRenderTexture(for: view) else {
                        return
                    }
                    let source = index < pass.imageUniformSources.count ? pass.imageUniformSources[index] : nil
                    if let source {
                        renderPassSource(
                            source,
                            into: texture,
                            commandBuffer: commandBuffer,
                            drawableSize: drawableSize,
                            currentTime: currentRenderTime(),
                            role: .primary
                        )
                    } else {
                        clearRenderTexture(texture, color: SIMD4<Float>(0, 0, 0, 0), commandBuffer: commandBuffer)
                    }
                    imageUniformTextures.append(texture)
                }
            }

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }

            var frameUniforms = PreviewUniforms(
                resolution: SIMD2(Float(drawableSize.width), Float(drawableSize.height)),
                time: currentRenderTime(),
                date: makeDateVector()
            )
            let floatUniforms = makeFloatUniformBuffer(from: pass.uniforms)
            let colorUniforms = makeColorUniformBuffer(from: pass.uniforms)
            let pointUniforms = makePointUniformBuffer(from: pass.uniforms)
            let point3Uniforms = makePoint3UniformBuffer(from: pass.uniforms)
            let point4Uniforms = makePoint4UniformBuffer(from: pass.uniforms)
            let boolUniforms = makeBoolUniformBuffer(from: pass.uniforms)

            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBytes(&frameUniforms, length: MemoryLayout<PreviewUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&frameUniforms, length: MemoryLayout<PreviewUniforms>.stride, index: 0)
            floatUniforms.withUnsafeBytes { bytes in
                if let baseAddress = bytes.baseAddress {
                    encoder.setFragmentBytes(baseAddress, length: bytes.count, index: 1)
                }
            }
            colorUniforms.withUnsafeBytes { bytes in
                if let baseAddress = bytes.baseAddress {
                    encoder.setFragmentBytes(baseAddress, length: bytes.count, index: 2)
                }
            }
            pointUniforms.withUnsafeBytes { bytes in
                if let baseAddress = bytes.baseAddress {
                    encoder.setFragmentBytes(baseAddress, length: bytes.count, index: 3)
                }
            }
            point3Uniforms.withUnsafeBytes { bytes in
                if let baseAddress = bytes.baseAddress {
                    encoder.setFragmentBytes(baseAddress, length: bytes.count, index: 5)
                }
            }
            point4Uniforms.withUnsafeBytes { bytes in
                if let baseAddress = bytes.baseAddress {
                    encoder.setFragmentBytes(baseAddress, length: bytes.count, index: 6)
                }
            }
            boolUniforms.withUnsafeBytes { bytes in
                if let baseAddress = bytes.baseAddress {
                    encoder.setFragmentBytes(baseAddress, length: bytes.count, index: 4)
                }
            }
            for (index, texture) in imageUniformTextures.enumerated() {
                encoder.setFragmentTexture(texture, index: index)
                encoder.setFragmentSamplerState(samplerState, index: index)
            }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        private func declaredResourceBindingCount(in source: String, attribute: String) -> Int {
            let pattern = #"\[\[\#(attribute)\((\d+)\)\]\]"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return 0
            }
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            let maxIndex = regex.matches(in: source, range: range).compactMap { match -> Int? in
                guard
                    match.numberOfRanges > 1,
                    let matchRange = Range(match.range(at: 1), in: source)
                else {
                    return nil
                }
                return Int(source[matchRange])
            }.max()
            return maxIndex.map { $0 + 1 } ?? 0
        }

        private func encodeCompositePass(
            into descriptor: MTLRenderPassDescriptor,
            commandBuffer: MTLCommandBuffer,
            primaryTexture: MTLTexture,
            secondaryTexture: MTLTexture,
            amount: Float
        ) {
            guard
                let compositePipelineState,
                let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
            else {
                return
            }

            var mixUniforms = MixUniforms(amount: amount)
            encoder.setRenderPipelineState(compositePipelineState)
            encoder.setFragmentTexture(primaryTexture, index: 0)
            encoder.setFragmentTexture(secondaryTexture, index: 1)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.setFragmentBytes(&mixUniforms, length: MemoryLayout<MixUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        private func encodeTransitionPass(
            _ pass: PreviewTransitionPass,
            into descriptor: MTLRenderPassDescriptor,
            commandBuffer: MTLCommandBuffer,
            drawableSize: CGSize,
            currentTime: Float
        ) {
            guard
                let transitionPipelineState,
                let primaryTexture = makeRenderTexture(for: drawableSize),
                let secondaryTexture = makeRenderTexture(for: drawableSize)
            else {
                return
            }

            renderPassSource(
                pass.primary,
                into: primaryTexture,
                commandBuffer: commandBuffer,
                drawableSize: drawableSize,
                currentTime: currentTime,
                role: .primary
            )

            renderPassSource(
                pass.secondary,
                into: secondaryTexture,
                commandBuffer: commandBuffer,
                drawableSize: drawableSize,
                currentTime: currentTime,
                role: .secondary
            )

            var uniforms = TransitionUniformsGPU(
                progress: pass.progress,
                softness: pass.softness,
                styleIndex: UInt32(Self.transitionStyleIndex(for: pass.style))
            )

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }

            encoder.setRenderPipelineState(transitionPipelineState)
            encoder.setFragmentTexture(primaryTexture, index: 0)
            encoder.setFragmentTexture(secondaryTexture, index: 1)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TransitionUniformsGPU>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        private func encodeTransformPass(
            _ pass: PreviewTransformPass,
            into descriptor: MTLRenderPassDescriptor,
            commandBuffer: MTLCommandBuffer,
            drawableSize: CGSize,
            currentTime: Float
        ) {
            guard
                let transformPipelineState,
                let sourceTexture = makeRenderTexture(for: drawableSize)
            else {
                return
            }

            renderPassSource(
                pass.source,
                into: sourceTexture,
                commandBuffer: commandBuffer,
                drawableSize: drawableSize,
                currentTime: currentTime,
                role: .primary
            )

            var uniforms = TransformUniformsGPU(
                position: SIMD3<Float>(pass.x, pass.y, pass.z),
                scale: SIMD2<Float>(pass.scaleX, pass.scaleY),
                rotationRadians: SIMD3<Float>(
                    pass.rotationDegreesX * (.pi / 180.0),
                    pass.rotationDegreesY * (.pi / 180.0),
                    pass.rotationDegreesZ * (.pi / 180.0)
                ),
                opacity: pass.opacity,
                tint: pass.tint
            )

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }

            encoder.setRenderPipelineState(transformPipelineState)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<TransformUniformsGPU>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TransformUniformsGPU>.stride, index: 0)
            encoder.setFragmentTexture(sourceTexture, index: 0)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        private func encodeLineBatchPass(
            _ pass: PreviewLineBatchPass,
            into descriptor: MTLRenderPassDescriptor,
            commandBuffer: MTLCommandBuffer
        ) {
            guard
                let linePipelineState,
                pass.instances.isEmpty == false,
                let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
            else {
                return
            }

            let instances = pass.instances.map {
                LineInstanceGPU(
                    position: $0.position,
                    scale: $0.scale,
                    rotationRadiansZ: $0.rotationRadiansZ,
                    color: $0.color
                )
            }

            guard let device else {
                encoder.endEncoding()
                return
            }

            encoder.setRenderPipelineState(linePipelineState)
            let bufferLength = instances.count * MemoryLayout<LineInstanceGPU>.stride
            guard
                bufferLength > 0,
                let instanceBuffer = device.makeBuffer(
                    bytes: instances,
                    length: bufferLength,
                    options: .storageModeShared
                )
            else {
                encoder.endEncoding()
                return
            }

            encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
            encoder.endEncoding()
        }

        private func renderPassSource(
            _ source: PreviewPassSource,
            into texture: MTLTexture,
            commandBuffer: MTLCommandBuffer,
            drawableSize: CGSize,
            currentTime: Float,
            role: PipelineRole
        ) {
            clearRenderTexture(texture, color: SIMD4<Float>(0, 0, 0, 0), commandBuffer: commandBuffer)
            guard let descriptor = offscreenRenderPassDescriptor(for: texture) else { return }
            renderPassSource(
                source,
                into: descriptor,
                commandBuffer: commandBuffer,
                drawableSize: drawableSize,
                currentTime: currentTime,
                role: role
            )
        }

        private func renderPassSource(
            _ source: PreviewPassSource,
            into descriptor: MTLRenderPassDescriptor,
            commandBuffer: MTLCommandBuffer,
            drawableSize: CGSize,
            currentTime: Float,
            role: PipelineRole
        ) {
            switch source {
            case .shader(let pass):
                let pipelineState = view.flatMap { currentView in
                    device.flatMap { currentDevice in
                        compileShaderPipeline(source: pass.metalSource, for: currentView, device: currentDevice)
                    }
                }
                guard let pipelineState else { return }
                encodeShaderPass(
                    pass,
                    with: pipelineState,
                    into: descriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: drawableSize
                )
            case .trail(let pass):
                guard let trailPipelineState else { return }
                encodeTrailPass(
                    pass,
                    with: trailPipelineState,
                    into: descriptor,
                    commandBuffer: commandBuffer,
                    currentTime: currentTime
                )
            case .circle(let pass):
                guard let circlePipelineState else { return }
                encodeCirclePass(
                    pass,
                    with: circlePipelineState,
                    into: descriptor,
                    commandBuffer: commandBuffer
                )
            case .clear(let pass):
                encodeClearPass(
                    color: pass.color,
                    into: descriptor,
                    commandBuffer: commandBuffer
                )
            case .image(let pass):
                guard let videoPipelineState else { return }
                encodeImagePass(
                    pass,
                    with: videoPipelineState,
                    into: descriptor,
                    commandBuffer: commandBuffer
                )
            case .videoPlayer(let pass):
                guard let videoPipelineState else { return }
                encodeVideoPlayerPass(
                    pass,
                    with: videoPipelineState,
                    into: descriptor,
                    commandBuffer: commandBuffer
                )
            case .video:
                guard let videoPipelineState else { return }
                encodeVideoPass(
                    with: videoPipelineState,
                    into: descriptor,
                    commandBuffer: commandBuffer
                )
            case .coreImage(let pass):
                encodeCoreImagePass(
                    pass,
                    into: descriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: drawableSize,
                    currentTime: currentTime
                )
            case .underwater(let pass):
                encodeUnderwaterPass(
                    pass,
                    into: descriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: drawableSize,
                    currentTime: currentTime
                )
            case .mix(let primary, let secondary, let amount):
                guard
                    let primaryTexture = makeRenderTexture(for: drawableSize),
                    let secondaryTexture = makeRenderTexture(for: drawableSize)
                else {
                    return
                }

                renderPassSource(
                    primary,
                    into: primaryTexture,
                    commandBuffer: commandBuffer,
                    drawableSize: drawableSize,
                    currentTime: currentTime,
                    role: .primary
                )
                renderPassSource(
                    secondary,
                    into: secondaryTexture,
                    commandBuffer: commandBuffer,
                    drawableSize: drawableSize,
                    currentTime: currentTime,
                    role: .secondary
                )

                encodeCompositePass(
                    into: descriptor,
                    commandBuffer: commandBuffer,
                    primaryTexture: primaryTexture,
                    secondaryTexture: secondaryTexture,
                    amount: amount
                )
            case .transform(let pass):
                encodeTransformPass(
                    pass,
                    into: descriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: drawableSize,
                    currentTime: currentTime
                )
            case .lineBatch(let pass):
                encodeLineBatchPass(
                    pass,
                    into: descriptor,
                    commandBuffer: commandBuffer
                )
            case .scene3DPrimitive(let pass):
                encodeScene3DPrimitivePass(
                    pass,
                    into: descriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: drawableSize,
                    currentTime: currentTime
                )
            case .scene3DText(let pass):
                encodeScene3DTextPass(
                    pass,
                    into: descriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: drawableSize,
                    currentTime: currentTime
                )
            case .scene3DModel(let pass):
                encodeScene3DModelPass(
                    pass,
                    into: descriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: drawableSize,
                    currentTime: currentTime
                )
            case .scene3DGaussianSplat(let pass):
                encodeScene3DGaussianSplatPass(
                    pass,
                    into: descriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: drawableSize,
                    currentTime: currentTime
                )
            case .scene3DParticle(let pass):
                encodeScene3DParticlePass(
                    pass,
                    into: descriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: drawableSize,
                    currentTime: currentTime
                )
            case .scene3DRender(let pass):
                encodeScene3DRenderPass(
                    pass,
                    into: descriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: drawableSize,
                    currentTime: currentTime
                )
            case .scene3DSource:
                break
            case .transition(let pass):
                encodeTransitionPass(
                    pass,
                    into: descriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: drawableSize,
                    currentTime: currentTime
                )
            case .layers(let layers, let opacity):
                guard
                    let displayPipelineState = videoPipelineState,
                    let baseTexture = makeRenderTexture(for: drawableSize),
                    let overlayTexture = makeRenderTexture(for: drawableSize),
                    let compositeTexture = makeRenderTexture(for: drawableSize)
                else {
                    return
                }

                var currentBaseTexture = baseTexture
                var scratchTexture = compositeTexture
                clearRenderTexture(currentBaseTexture, color: SIMD4<Float>(0, 0, 0, 0), commandBuffer: commandBuffer)

                for (index, layer) in layers.enumerated() {
                    clearRenderTexture(overlayTexture, color: SIMD4<Float>(0, 0, 0, 0), commandBuffer: commandBuffer)
                    renderPassSource(
                        layer.source,
                        into: overlayTexture,
                        commandBuffer: commandBuffer,
                        drawableSize: drawableSize,
                        currentTime: currentTime,
                        role: index.isMultiple(of: 2) ? .secondary : .primary
                    )
                    encodeLayerCompositePass(
                        into: scratchTexture,
                        commandBuffer: commandBuffer,
                        backgroundTexture: currentBaseTexture,
                        foregroundTexture: overlayTexture,
                        opacity: opacity * layer.opacity
                    )
                    swap(&currentBaseTexture, &scratchTexture)
                }

                encodeTextureDisplayPass(
                    texture: currentBaseTexture,
                    with: displayPipelineState,
                    into: descriptor,
                    commandBuffer: commandBuffer
                )
            case .feedback(let pass):
                encodeFeedbackPass(
                    pass,
                    into: descriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: drawableSize,
                    currentTime: currentTime
                )
            case .feedbackHistory(let nodeID):
                guard let displayPipelineState = videoPipelineState else { return }
                let historyTexture = feedbackHistoryTexture(
                    for: nodeID,
                    drawableSize: drawableSize,
                    commandBuffer: commandBuffer
                )
                encodeTextureDisplayPass(
                    texture: historyTexture,
                    with: displayPipelineState,
                    into: descriptor,
                    commandBuffer: commandBuffer
                )
            }
        }

        private func encodeLayerCompositePass(
            into descriptor: MTLRenderPassDescriptor,
            commandBuffer: MTLCommandBuffer,
            backgroundTexture: MTLTexture,
            foregroundTexture: MTLTexture,
            opacity: Float
        ) {
            guard
                let layerCompositePipelineState,
                let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
            else {
                return
            }

            var uniforms = MixUniforms(amount: opacity)
            encoder.setRenderPipelineState(layerCompositePipelineState)
            encoder.setFragmentTexture(backgroundTexture, index: 0)
            encoder.setFragmentTexture(foregroundTexture, index: 1)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MixUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        private func encodeLayerCompositePass(
            into texture: MTLTexture,
            commandBuffer: MTLCommandBuffer,
            backgroundTexture: MTLTexture,
            foregroundTexture: MTLTexture,
            opacity: Float
        ) {
            guard let descriptor = offscreenRenderPassDescriptor(for: texture) else {
                return
            }

            encodeLayerCompositePass(
                into: descriptor,
                commandBuffer: commandBuffer,
                backgroundTexture: backgroundTexture,
                foregroundTexture: foregroundTexture,
                opacity: opacity
            )
        }

        private func encodeFeedbackPass(
            _ pass: PreviewFeedbackPass,
            into descriptor: MTLRenderPassDescriptor,
            commandBuffer: MTLCommandBuffer,
            drawableSize: CGSize,
            currentTime: Float
        ) {
            guard
                let outputTexture = makeRenderTexture(for: drawableSize),
                let currentTexture = makeRenderTexture(for: drawableSize),
                let displayPipelineState = videoPipelineState
            else {
                return
            }

            let historyTexture = feedbackHistoryTexture(for: pass.nodeID, drawableSize: drawableSize, commandBuffer: commandBuffer)

            renderPassSource(
                pass.source,
                into: currentTexture,
                commandBuffer: commandBuffer,
                drawableSize: drawableSize,
                currentTime: currentTime,
                role: .primary
            )

            encodeFeedbackCompositePass(
                into: outputTexture,
                commandBuffer: commandBuffer,
                currentTexture: currentTexture,
                historyTexture: historyTexture,
                level: pass.level,
                blendMode: pass.blendMode
            )

            feedbackHistoryTextures[pass.nodeID] = outputTexture

            encodeTextureDisplayPass(
                texture: outputTexture,
                with: displayPipelineState,
                into: descriptor,
                commandBuffer: commandBuffer
            )
        }

        private func encodeUnderwaterTexturePass(
            texture: MTLTexture,
            with pipelineState: MTLRenderPipelineState,
            into descriptor: MTLRenderPassDescriptor,
            commandBuffer: MTLCommandBuffer,
            drawableSize: CGSize,
            currentTime: Float,
            distortion: Float,
            scale: Float
        ) {
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }

            var uniforms = UnderwaterUniformsGPU(
                renderSize: SIMD2(Float(drawableSize.width), Float(drawableSize.height)),
                time: currentTime,
                scale: max(scale, 0.001),
                distortion: max(distortion, 0.0),
                octaves: 5,
                lacunarity: 2.0,
                gain: 0.5,
                amplitude: 0.6,
                textureScale: 1.03,
                uvClampMargin: 0.002
            )

            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<UnderwaterUniformsGPU>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        private func encodeUnderwaterPass(
            _ pass: PreviewUnderwaterPass,
            into descriptor: MTLRenderPassDescriptor,
            commandBuffer: MTLCommandBuffer,
            drawableSize: CGSize,
            currentTime: Float
        ) {
            guard
                let underwaterPipelineState,
                let sourceTexture = makeRenderTexture(for: drawableSize)
            else {
                return
            }

            renderPassSource(
                pass.source,
                into: sourceTexture,
                commandBuffer: commandBuffer,
                drawableSize: drawableSize,
                currentTime: currentTime,
                role: .primary
            )

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }

            var uniforms = UnderwaterUniformsGPU(
                renderSize: SIMD2(Float(drawableSize.width), Float(drawableSize.height)),
                time: currentTime,
                scale: pass.scale,
                distortion: pass.distortion,
                octaves: UInt32(max(pass.octaves, 1)),
                lacunarity: pass.lacunarity,
                gain: pass.gain,
                amplitude: pass.amplitude,
                textureScale: pass.textureScale,
                uvClampMargin: pass.uvClampMargin
            )

            encoder.setRenderPipelineState(underwaterPipelineState)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<UnderwaterUniformsGPU>.stride, index: 0)
            encoder.setFragmentTexture(sourceTexture, index: 0)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        private func encodeCoreImagePass(
            _ pass: PreviewCoreImagePass,
            into descriptor: MTLRenderPassDescriptor,
            commandBuffer: MTLCommandBuffer,
            drawableSize: CGSize,
            currentTime: Float
        ) {
            guard
                let displayPipelineState = videoPipelineState,
                let coreImageEffectPipelineState,
                let sourceTexture = makeRenderTexture(for: drawableSize),
                let outputTexture = makeRenderTexture(for: drawableSize)
            else {
                return
            }

            renderPassSource(
                pass.source,
                into: sourceTexture,
                commandBuffer: commandBuffer,
                drawableSize: drawableSize,
                currentTime: currentTime,
                role: .primary
            )

            encodeCoreImageEffectPass(
                pass,
                with: coreImageEffectPipelineState,
                sourceTexture: sourceTexture,
                outputTexture: outputTexture,
                commandBuffer: commandBuffer,
                drawableSize: drawableSize
            )

            encodeTextureDisplayPass(
                texture: outputTexture,
                with: displayPipelineState,
                into: descriptor,
                commandBuffer: commandBuffer
            )
        }

        private func encodeClearPass(
            color: SIMD4<Float>,
            into descriptor: MTLRenderPassDescriptor,
            commandBuffer: MTLCommandBuffer
        ) {
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = MTLClearColor(
                red: Double(color.x),
                green: Double(color.y),
                blue: Double(color.z),
                alpha: Double(color.w)
            )
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }
            encoder.endEncoding()
        }

        private func clearRenderTexture(
            _ texture: MTLTexture,
            color: SIMD4<Float>,
            commandBuffer: MTLCommandBuffer
        ) {
            guard let descriptor = offscreenRenderPassDescriptor(for: texture) else {
                return
            }
            encodeClearPass(color: color, into: descriptor, commandBuffer: commandBuffer)
        }

        private func encodeFeedbackCompositePass(
            into texture: MTLTexture,
            commandBuffer: MTLCommandBuffer,
            currentTexture: MTLTexture,
            historyTexture: MTLTexture,
            level: Float,
            blendMode: FeedbackBlendMode
        ) {
            guard
                let descriptor = offscreenRenderPassDescriptor(for: texture),
                let feedbackPipelineState,
                let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
            else {
                return
            }

            var uniforms = FeedbackUniformsGPU(
                level: level,
                blendMode: UInt32(Self.blendModeIndex(for: blendMode))
            )

            encoder.setRenderPipelineState(feedbackPipelineState)
            encoder.setFragmentTexture(currentTexture, index: 0)
            encoder.setFragmentTexture(historyTexture, index: 1)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FeedbackUniformsGPU>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        private func encodeVideoPass(
            with pipelineState: MTLRenderPipelineState,
            into descriptor: MTLRenderPassDescriptor,
            commandBuffer: MTLCommandBuffer
        ) {
            guard
                let device,
                let texture = VideoInputMonitor.shared.makeTexture(device: device)
            else {
                return
            }

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }

            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        private func encodeImagePass(
            _ pass: PreviewImagePass,
            with pipelineState: MTLRenderPipelineState,
            into descriptor: MTLRenderPassDescriptor,
            commandBuffer: MTLCommandBuffer
        ) {
            guard
                let device,
                let texture = texture(for: pass, device: device),
                let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
            else {
                return
            }

            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        private func encodeVideoPlayerPass(
            _ pass: PreviewVideoPlayerPass,
            with pipelineState: MTLRenderPipelineState,
            into descriptor: MTLRenderPassDescriptor,
            commandBuffer: MTLCommandBuffer
        ) {
            guard
                let texture = texture(for: pass),
                let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
            else {
                return
            }

            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        private func encodeTextureDisplayPass(
            texture: MTLTexture,
            with pipelineState: MTLRenderPipelineState,
            into descriptor: MTLRenderPassDescriptor,
            commandBuffer: MTLCommandBuffer
        ) {
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }

            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        private func encodeScene3DPrimitivePass(
            _ pass: PreviewScene3DPrimitivePass,
            into descriptor: MTLRenderPassDescriptor,
            commandBuffer: MTLCommandBuffer,
            drawableSize: CGSize,
            currentTime: Float
        ) {
            guard
                let device,
                let displayPipelineState = videoPipelineState,
                let outputTexture = makeRenderTexture(for: drawableSize),
                let outputDescriptor = offscreenRenderPassDescriptor(for: outputTexture, includeDepth: true)
            else {
                return
            }

            outputDescriptor.colorAttachments[0].clearColor = MTLClearColor(
                red: 0,
                green: 0,
                blue: 0,
                alpha: Double(pass.settings.backgroundAlpha)
            )

            let materialTextures = scene3DMaterialTextures(
                from: pass.materialMaps,
                commandBuffer: commandBuffer,
                drawableSize: drawableSize,
                currentTime: currentTime
            )

            let renderer = sceneRenderer(for: pass, device: device)
            renderer.scene = makeScene(for: pass, materialTextures: materialTextures)
            renderer.pointOfView = renderer.scene?.rootNode.childNode(withName: "camera", recursively: true)
            renderer.render(
                atTime: TimeInterval(currentTime),
                viewport: CGRect(origin: .zero, size: drawableSize),
                commandBuffer: commandBuffer,
                passDescriptor: outputDescriptor
            )

            encodeTextureDisplayPass(
                texture: outputTexture,
                with: displayPipelineState,
                into: descriptor,
                commandBuffer: commandBuffer
            )
        }

        private func encodeScene3DTextPass(
            _ pass: PreviewScene3DTextPass,
            into descriptor: MTLRenderPassDescriptor,
            commandBuffer: MTLCommandBuffer,
            drawableSize: CGSize,
            currentTime: Float
        ) {
            guard
                let device,
                let displayPipelineState = videoPipelineState,
                let outputTexture = makeRenderTexture(for: drawableSize),
                let outputDescriptor = offscreenRenderPassDescriptor(for: outputTexture, includeDepth: true)
            else {
                return
            }

            outputDescriptor.colorAttachments[0].clearColor = MTLClearColor(
                red: 0,
                green: 0,
                blue: 0,
                alpha: Double(pass.settings.backgroundAlpha)
            )

            let materialTextures = scene3DMaterialTextures(
                from: pass.materialMaps,
                commandBuffer: commandBuffer,
                drawableSize: drawableSize,
                currentTime: currentTime
            )

            let renderer = sceneRenderer(for: pass, device: device)
            renderer.scene = makeScene(for: pass, materialTextures: materialTextures)
            renderer.pointOfView = renderer.scene?.rootNode.childNode(withName: "camera", recursively: true)
            renderer.render(
                atTime: TimeInterval(currentTime),
                viewport: CGRect(origin: .zero, size: drawableSize),
                commandBuffer: commandBuffer,
                passDescriptor: outputDescriptor
            )

            encodeTextureDisplayPass(
                texture: outputTexture,
                with: displayPipelineState,
                into: descriptor,
                commandBuffer: commandBuffer
            )
        }

        private func encodeScene3DModelPass(
            _ pass: PreviewScene3DModelPass,
            into descriptor: MTLRenderPassDescriptor,
            commandBuffer: MTLCommandBuffer,
            drawableSize: CGSize,
            currentTime: Float
        ) {
            guard
                let device,
                let displayPipelineState = videoPipelineState,
                let outputTexture = makeRenderTexture(for: drawableSize),
                let outputDescriptor = offscreenRenderPassDescriptor(for: outputTexture, includeDepth: true)
            else {
                return
            }

            outputDescriptor.colorAttachments[0].clearColor = MTLClearColor(
                red: 0,
                green: 0,
                blue: 0,
                alpha: Double(pass.settings.backgroundAlpha)
            )

            let materialTextures = scene3DMaterialTextures(
                from: pass.materialMaps,
                commandBuffer: commandBuffer,
                drawableSize: drawableSize,
                currentTime: currentTime
            )

            let renderer = sceneRenderer(for: pass, device: device)
            renderer.scene = scene3DModel(
                for: pass,
                materialTextures: materialTextures
            )
            renderer.pointOfView = renderer.scene?.rootNode.childNode(withName: "camera", recursively: true)
            renderer.isPlaying = liveIsRunning
            renderer.render(
                atTime: TimeInterval(currentTime),
                viewport: CGRect(origin: .zero, size: drawableSize),
                commandBuffer: commandBuffer,
                passDescriptor: outputDescriptor
            )

            encodeTextureDisplayPass(
                texture: outputTexture,
                with: displayPipelineState,
                into: descriptor,
                commandBuffer: commandBuffer
            )
        }

        private func encodeScene3DParticlePass(
            _ pass: PreviewScene3DParticlePass,
            into descriptor: MTLRenderPassDescriptor,
            commandBuffer: MTLCommandBuffer,
            drawableSize: CGSize,
            currentTime: Float
        ) {
            guard
                let device,
                let displayPipelineState = videoPipelineState,
                let outputTexture = makeRenderTexture(for: drawableSize),
                let outputDescriptor = offscreenRenderPassDescriptor(for: outputTexture, includeDepth: true)
            else {
                return
            }

            outputDescriptor.colorAttachments[0].clearColor = MTLClearColor(
                red: 0,
                green: 0,
                blue: 0,
                alpha: Double(pass.settings.backgroundAlpha)
            )

            let spriteImage = particleSpriteImage(
                from: pass.spriteSource,
                commandBuffer: commandBuffer,
                drawableSize: drawableSize,
                currentTime: currentTime
            )
            let renderer = sceneRenderer(for: pass, device: device)
            renderer.scene = scene3DParticleScene(for: pass, spriteImage: spriteImage, currentTime: currentTime)
            updateParticleSpriteImage(in: renderer.scene, spriteImage: spriteImage)
            renderer.pointOfView = renderer.scene?.rootNode.childNode(withName: "camera", recursively: true)
            renderer.isPlaying = liveIsRunning
            renderer.render(
                atTime: TimeInterval(currentTime),
                viewport: CGRect(origin: .zero, size: drawableSize),
                commandBuffer: commandBuffer,
                passDescriptor: outputDescriptor
            )

            encodeTextureDisplayPass(
                texture: outputTexture,
                with: displayPipelineState,
                into: descriptor,
                commandBuffer: commandBuffer
            )
        }

        private func encodeScene3DGaussianSplatPass(
            _ pass: PreviewScene3DGaussianSplatPass,
            into descriptor: MTLRenderPassDescriptor,
            commandBuffer: MTLCommandBuffer,
            drawableSize: CGSize,
            currentTime: Float
        ) {
            guard
                let pipelineState = gaussianSplatPipelineState,
                let bufferEntry = gaussianSplatBuffer(for: pass),
                let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
            else {
                return
            }

            var uniforms = GaussianSplatUniformsGPU(
                resolution: SIMD2<Float>(Float(max(drawableSize.width, 1)), Float(max(drawableSize.height, 1))),
                position: SIMD3<Float>(Float(pass.settings.positionX), Float(pass.settings.positionY), Float(pass.settings.positionZ)),
                scale: Float(max(0.001, pass.settings.scale)),
                rotationRadians: SIMD3<Float>(
                    Float(pass.settings.rotationX * .pi / 180.0),
                    Float(pass.settings.rotationY * .pi / 180.0),
                    Float(pass.settings.rotationZ * .pi / 180.0)
                ),
                cameraDistance: Float(pass.settings.cameraDistance),
                cameraOrbitRadians: Float(pass.settings.cameraOrbit * .pi / 180.0),
                cameraPitchRadians: Float(pass.settings.cameraPitch * .pi / 180.0),
                cameraPan: SIMD2<Float>(Float(pass.settings.cameraPanX), Float(pass.settings.cameraPanY)),
                pointSize: Float(max(0.1, pass.settings.pointSize)),
                opacity: Float(max(0.0, min(1.0, pass.settings.opacity))),
                explode: Float(max(0.0, pass.settings.explode)),
                chaos: Float(max(0.0, min(1.0, pass.settings.chaos))),
                particleSpeed: Float(max(0.0, pass.settings.particleSpeed)),
                particleGravity: Float(pass.settings.particleGravity),
                particleTurbulence: Float(max(0.0, pass.settings.particleTurbulence)),
                particleBoundary: Float(max(0.1, pass.settings.particleBoundary)),
                time: currentTime,
                isPanorama: pass.settings.panoramaImageData.isEmpty ? 0.0 : 1.0
            )

            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBuffer(bufferEntry.buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<GaussianSplatUniformsGPU>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: bufferEntry.count)
            encoder.endEncoding()
        }

        private func encodeScene3DRenderPass(
            _ pass: PreviewScene3DRenderPass,
            into descriptor: MTLRenderPassDescriptor,
            commandBuffer: MTLCommandBuffer,
            drawableSize: CGSize,
            currentTime: Float
        ) {
            guard
                let displayPipelineState = videoPipelineState,
                let texture = scene3DRenderTexture(
                    for: pass,
                    commandBuffer: commandBuffer,
                    drawableSize: drawableSize,
                    currentTime: currentTime
                )
            else {
                return
            }

            encodeTextureDisplayPass(
                texture: texture,
                with: displayPipelineState,
                into: descriptor,
                commandBuffer: commandBuffer
            )
        }

        private func scene3DRenderTexture(
            for pass: PreviewScene3DRenderPass,
            commandBuffer: MTLCommandBuffer,
            drawableSize: CGSize,
            currentTime: Float
        ) -> MTLTexture? {
            guard let device else { return nil }

            let cacheKey = [
                pass.nodeID.uuidString,
                "\(Int(max(drawableSize.width, 1)))x\(Int(max(drawableSize.height, 1)))",
                String(pass.cameraDistance),
                String(pass.cameraOrbit),
                String(pass.cameraPitch),
                String(pass.cameraPanX),
                String(pass.cameraPanY),
                String(pass.backgroundAlpha),
                String(pass.defaultLightIntensity),
                String(pass.waterDistortion),
                String(pass.waterScale),
                String(pass.waterSpeed),
                pass.sources.map { signature(for: $0) }.joined(separator: ",")
            ].joined(separator: "|")

            if let cached = frameScene3DRenderTextures[cacheKey] {
                return cached
            }

            guard
                let outputTexture = makeRenderTexture(for: drawableSize),
                let outputDescriptor = offscreenRenderPassDescriptor(for: outputTexture, includeDepth: true)
            else {
                return nil
            }

            outputDescriptor.colorAttachments[0].clearColor = MTLClearColor(
                red: 0,
                green: 0,
                blue: 0,
                alpha: Double(pass.backgroundAlpha)
            )

            var gaussianSplatPasses: [PreviewScene3DGaussianSplatPass] = []
            for source in pass.sources {
                appendGaussianSplatPasses(from: source, renderPass: pass, into: &gaussianSplatPasses)
            }

            let depthTexture = outputDescriptor.depthAttachment.texture
            if !gaussianSplatPasses.isEmpty {
                // Draw splats first as the environment layer, then let SceneKit render
                // models, lights, and particles over it with a fresh depth buffer.
                outputDescriptor.depthAttachment.texture = nil
                for gaussianSplatPass in gaussianSplatPasses {
                    encodeScene3DGaussianSplatPass(
                        gaussianSplatPass,
                        into: outputDescriptor,
                        commandBuffer: commandBuffer,
                        drawableSize: drawableSize,
                        currentTime: currentTime
                    )
                    outputDescriptor.colorAttachments[0].loadAction = .load
                }
                outputDescriptor.depthAttachment.texture = depthTexture
                outputDescriptor.depthAttachment.loadAction = .clear
                outputDescriptor.colorAttachments[0].loadAction = .load
            }

            let renderer = sceneRenderer(for: pass, device: device)
            renderer.scene = scene3DRenderScene(
                for: pass,
                commandBuffer: commandBuffer,
                drawableSize: drawableSize,
                currentTime: currentTime
            )
            renderer.pointOfView = renderer.scene?.rootNode.childNode(withName: "camera", recursively: true)
            renderer.isPlaying = liveIsRunning
            renderer.render(
                atTime: TimeInterval(currentTime),
                viewport: CGRect(origin: .zero, size: drawableSize),
                commandBuffer: commandBuffer,
                passDescriptor: outputDescriptor
            )

            if pass.waterDistortion > 0.0001,
               let underwaterPipelineState,
               let distortedTexture = makeRenderTexture(for: drawableSize),
               let distortedDescriptor = offscreenRenderPassDescriptor(for: distortedTexture) {
                encodeUnderwaterTexturePass(
                    texture: outputTexture,
                    with: underwaterPipelineState,
                    into: distortedDescriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: drawableSize,
                    currentTime: currentTime * max(pass.waterSpeed, 0.0),
                    distortion: pass.waterDistortion,
                    scale: pass.waterScale
                )
                frameScene3DRenderTextures[cacheKey] = distortedTexture
                return distortedTexture
            }

            frameScene3DRenderTextures[cacheKey] = outputTexture
            return outputTexture
        }

        private func scene3DRenderScene(
            for pass: PreviewScene3DRenderPass,
            commandBuffer: MTLCommandBuffer,
            drawableSize: CGSize,
            currentTime: Float
        ) -> SCNScene {
            // Scene render nodes can contain animated models and live material textures.
            // Rebuild the lightweight composite scene each frame so layer outputs do not
            // hold onto stale SceneKit nodes/textures when the render node is used as a shader.
            makeScene(
                for: pass,
                commandBuffer: commandBuffer,
                drawableSize: drawableSize,
                currentTime: currentTime
            )
        }

        private func appendGaussianSplatPasses(
            from source: PreviewScene3DSource,
            renderPass: PreviewScene3DRenderPass,
            into passes: inout [PreviewScene3DGaussianSplatPass]
        ) {
            switch source {
            case .gaussianSplat(let gaussianSplatPass):
                var settings = gaussianSplatPass.settings
                settings.cameraDistance = Double(renderPass.cameraDistance)
                settings.cameraOrbit = Double(renderPass.cameraOrbit)
                settings.cameraPitch = Double(renderPass.cameraPitch)
                settings.cameraPanX = Double(renderPass.cameraPanX)
                settings.cameraPanY = Double(renderPass.cameraPanY)
                passes.append(PreviewScene3DGaussianSplatPass(
                    nodeID: gaussianSplatPass.nodeID,
                    settings: settings
                ))
            case .transform(_, let child, let x, let y, let z, let scaleX, let scaleY, let scaleZ, let rotationX, let rotationY, let rotationZ):
                let startIndex = passes.count
                appendGaussianSplatPasses(from: child, renderPass: renderPass, into: &passes)
                for index in startIndex..<passes.count {
                    var settings = passes[index].settings
                    settings.positionX += Double(x)
                    settings.positionY += Double(y)
                    settings.positionZ += Double(z)
                    settings.scale *= Double((scaleX + scaleY + scaleZ) / 3.0)
                    settings.rotationX += Double(rotationX)
                    settings.rotationY += Double(rotationY)
                    settings.rotationZ += Double(rotationZ)
                    passes[index] = PreviewScene3DGaussianSplatPass(
                        nodeID: passes[index].nodeID,
                        settings: settings
                    )
                }
            case .primitive, .text, .model, .particle, .light:
                break
            }
        }

        private func encodeTrailPass(
            _ pass: PreviewTrailPass,
            with pipelineState: MTLRenderPipelineState,
            into descriptor: MTLRenderPassDescriptor,
            commandBuffer: MTLCommandBuffer,
            currentTime: Float
        ) {
            updateTrailHistory(pass: pass, currentTime: currentTime)

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }

            var uniforms = TrailUniformsGPU(
                time: currentTime,
                radius: pass.radius,
                trailDuration: pass.duration,
                pointCount: UInt32(min(trailHistory.count, Self.maxTrailPoints))
            )
            let points = trailHistory.suffix(Int(Self.maxTrailPoints)).map {
                TrailPointGPU(pos: SIMD2(Float($0.position.x), Float($0.position.y)), t: $0.time)
            }
            var fallbackPoint = TrailPointGPU(pos: SIMD2<Float>(repeating: 0), t: 0)

            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TrailUniformsGPU>.stride, index: 0)
            if points.isEmpty {
                encoder.setFragmentBytes(&fallbackPoint, length: MemoryLayout<TrailPointGPU>.stride, index: 1)
            } else {
                points.withUnsafeBytes { bytes in
                    if let baseAddress = bytes.baseAddress {
                        encoder.setFragmentBytes(baseAddress, length: bytes.count, index: 1)
                    }
                }
            }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        private func compilePipelines(for view: MTKView, configuration: PreviewRenderConfiguration) {
            compiledSignature = signature(for: configuration)
            primaryPipelineState = nil
            secondaryPipelineState = nil
            compositePipelineState = nil
            transformPipelineState = nil
            linePipelineState = nil
            transitionPipelineState = nil
            layerCompositePipelineState = nil
            feedbackPipelineState = nil
            trailPipelineState = nil
            circlePipelineState = nil
            videoPipelineState = nil
            underwaterPipelineState = nil
            coreImageEffectPipelineState = nil
            gaussianSplatPipelineState = nil

            guard let device else { return }

            switch configuration {
            case .empty:
                return
            case .single(let pass):
                primaryPipelineState = compileShaderPipeline(source: pass.metalSource, for: view, device: device)
                if pass.imageUniformSources.isEmpty == false {
                    videoPipelineState = compileVideoPipeline(for: view, device: device)
                    for source in pass.imageUniformSources {
                        guard let source else { continue }
                        compilePipeline(
                            for: source,
                            role: .secondary,
                            view: view,
                            device: device
                        )
                    }
                }
            case .trail:
                trailPipelineState = compileTrailPipeline(for: view, device: device)
            case .circle:
                circlePipelineState = compileCirclePipeline(for: view, device: device)
            case .clear:
                return
            case .image:
                videoPipelineState = compileVideoPipeline(for: view, device: device)
            case .videoPlayer:
                videoPipelineState = compileVideoPipeline(for: view, device: device)
            case .video:
                videoPipelineState = compileVideoPipeline(for: view, device: device)
            case .coreImage(let pass):
                compilePipeline(for: pass.source, role: .primary, view: view, device: device)
                videoPipelineState = compileVideoPipeline(for: view, device: device)
                coreImageEffectPipelineState = compileCoreImageEffectPipeline(for: view, device: device)
            case .underwater(let pass):
                compilePipeline(for: pass.source, role: .primary, view: view, device: device)
                underwaterPipelineState = compileUnderwaterPipeline(for: view, device: device)
            case .feedback(let pass):
                compilePipeline(for: pass.source, role: .primary, view: view, device: device)
                feedbackPipelineState = compileFeedbackPipeline(for: view, device: device)
                videoPipelineState = compileVideoPipeline(for: view, device: device)
            case .mix(let primary, let secondary, _):
                compilePipeline(for: primary, role: .primary, view: view, device: device)
                compilePipeline(for: secondary, role: .secondary, view: view, device: device)
                compositePipelineState = compileCompositePipeline(for: view, device: device)
            case .transform(let pass):
                compilePipeline(for: pass.source, role: .primary, view: view, device: device)
                transformPipelineState = compileTransformPipeline(for: view, device: device)
            case .lineBatch:
                linePipelineState = compileLinePipeline(for: view, device: device)
            case .scene3DPrimitive(let pass):
                if let maps = pass.materialMaps {
                    if let diffuse = maps.diffuse {
                        compilePipeline(for: diffuse, role: .primary, view: view, device: device)
                    }
                    if let specular = maps.specular {
                        compilePipeline(for: specular, role: .secondary, view: view, device: device)
                    }
                    if let metallic = maps.metallic {
                        compilePipeline(for: metallic, role: .secondary, view: view, device: device)
                    }
                    if let bump = maps.bump {
                        compilePipeline(for: bump, role: .primary, view: view, device: device)
                    }
                    if let displacement = maps.displacement {
                        compilePipeline(for: displacement, role: .secondary, view: view, device: device)
                    }
                }
                videoPipelineState = compileVideoPipeline(for: view, device: device)
            case .scene3DText(let pass):
                if let maps = pass.materialMaps {
                    if let diffuse = maps.diffuse {
                        compilePipeline(for: diffuse, role: .primary, view: view, device: device)
                    }
                    if let specular = maps.specular {
                        compilePipeline(for: specular, role: .secondary, view: view, device: device)
                    }
                    if let metallic = maps.metallic {
                        compilePipeline(for: metallic, role: .secondary, view: view, device: device)
                    }
                    if let bump = maps.bump {
                        compilePipeline(for: bump, role: .primary, view: view, device: device)
                    }
                    if let displacement = maps.displacement {
                        compilePipeline(for: displacement, role: .secondary, view: view, device: device)
                    }
                }
                videoPipelineState = compileVideoPipeline(for: view, device: device)
            case .scene3DModel(let pass):
                if let maps = pass.materialMaps {
                    if let diffuse = maps.diffuse {
                        compilePipeline(for: diffuse, role: .primary, view: view, device: device)
                    }
                    if let specular = maps.specular {
                        compilePipeline(for: specular, role: .secondary, view: view, device: device)
                    }
                    if let metallic = maps.metallic {
                        compilePipeline(for: metallic, role: .secondary, view: view, device: device)
                    }
                    if let bump = maps.bump {
                        compilePipeline(for: bump, role: .primary, view: view, device: device)
                    }
                    if let displacement = maps.displacement {
                        compilePipeline(for: displacement, role: .secondary, view: view, device: device)
                    }
                }
                videoPipelineState = compileVideoPipeline(for: view, device: device)
            case .scene3DGaussianSplat:
                gaussianSplatPipelineState = compileGaussianSplatPipeline(for: view, device: device)
            case .scene3DParticle(let pass):
                if let spriteSource = pass.spriteSource {
                    compilePipeline(for: spriteSource, role: .primary, view: view, device: device)
                }
                videoPipelineState = compileVideoPipeline(for: view, device: device)
            case .scene3DRender(let pass):
                videoPipelineState = compileVideoPipeline(for: view, device: device)
                underwaterPipelineState = compileUnderwaterPipeline(for: view, device: device)
                for source in pass.sources {
                    compileScene3DSourcePipeline(source, view: view, device: device)
                }
            case .transition(let pass):
                compilePipeline(for: pass.primary, role: .primary, view: view, device: device)
                compilePipeline(for: pass.secondary, role: .secondary, view: view, device: device)
                transitionPipelineState = compileTransitionPipeline(for: view, device: device)
            case .layers(let layers, _):
                if let firstLayer = layers.first {
                    compilePipeline(for: firstLayer.source, role: .primary, view: view, device: device)
                }
                if layers.isEmpty == false {
                    layerCompositePipelineState = compileLayerCompositePipeline(for: view, device: device)
                    videoPipelineState = compileVideoPipeline(for: view, device: device)
                }
                for (index, layer) in layers.enumerated() {
                    compilePipeline(for: layer.source, role: index.isMultiple(of: 2) ? .secondary : .primary, view: view, device: device)
                }
            }
        }

        private func compileShaderPipeline(source: String, for view: MTKView, device: MTLDevice) -> MTLRenderPipelineState? {
            do {
                let library = try device.makeLibrary(source: source, options: nil)
                guard
                    let vertexFunction = library.makeFunction(name: "previewVertex"),
                    let fragmentFunction = library.makeFunction(name: "generatedFragment")
                else {
                    return nil
                }

                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertexFunction
                descriptor.fragmentFunction = fragmentFunction
                descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                let sourceID = source.hashValue
                if loggedShaderCompileFailures.insert(sourceID).inserted {
                    print("Metal shader compile failed: \(error)")
                }
                return nil
            }
        }

        private func compileCompositePipeline(for view: MTKView, device: MTLDevice) -> MTLRenderPipelineState? {
            do {
                let library = try device.makeLibrary(source: Self.mixShaderSource, options: nil)
                guard
                    let vertexFunction = library.makeFunction(name: "mixVertex"),
                    let fragmentFunction = library.makeFunction(name: "mixFragment")
                else {
                    return nil
                }

                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertexFunction
                descriptor.fragmentFunction = fragmentFunction
                descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                return nil
            }
        }

        private func compileTransitionPipeline(for view: MTKView, device: MTLDevice) -> MTLRenderPipelineState? {
            do {
                let library = try device.makeLibrary(source: Self.transitionShaderSource, options: nil)
                guard
                    let vertexFunction = library.makeFunction(name: "transitionVertex"),
                    let fragmentFunction = library.makeFunction(name: "transitionFragment")
                else {
                    return nil
                }

                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertexFunction
                descriptor.fragmentFunction = fragmentFunction
                descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                return nil
            }
        }

        private func compileTransformPipeline(for view: MTKView, device: MTLDevice) -> MTLRenderPipelineState? {
            do {
                let library = try device.makeLibrary(source: Self.transformShaderSource, options: nil)
                guard
                    let vertexFunction = library.makeFunction(name: "transformVertex"),
                    let fragmentFunction = library.makeFunction(name: "transformFragment")
                else {
                    return nil
                }

                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertexFunction
                descriptor.fragmentFunction = fragmentFunction
                descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                return nil
            }
        }

        private func compileLinePipeline(for view: MTKView, device: MTLDevice) -> MTLRenderPipelineState? {
            do {
                let library = try device.makeLibrary(source: Self.lineShaderSource, options: nil)
                guard
                    let vertexFunction = library.makeFunction(name: "lineVertex"),
                    let fragmentFunction = library.makeFunction(name: "lineFragment")
                else {
                    return nil
                }

                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertexFunction
                descriptor.fragmentFunction = fragmentFunction
                descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
                descriptor.colorAttachments[0].isBlendingEnabled = true
                descriptor.colorAttachments[0].rgbBlendOperation = .add
                descriptor.colorAttachments[0].alphaBlendOperation = .add
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                return nil
            }
        }

        private enum PipelineRole {
            case primary
            case secondary
        }

        private func compileScene3DMaterialPipelines(
            _ maps: PreviewScene3DMaterialMaps?,
            view: MTKView,
            device: MTLDevice
        ) {
            guard let maps else { return }
            videoPipelineState = compileVideoPipeline(for: view, device: device)
            let sources = [maps.diffuse, maps.specular, maps.metallic, maps.bump, maps.displacement]
            for source in sources {
                guard let source else { continue }
                compilePipeline(for: source, role: .secondary, view: view, device: device)
            }
        }

        private func compileScene3DSourcePipeline(
            _ source: PreviewScene3DSource,
            view: MTKView,
            device: MTLDevice
        ) {
            switch source {
            case .primitive(let pass):
                videoPipelineState = compileVideoPipeline(for: view, device: device)
                compileScene3DMaterialPipelines(pass.materialMaps, view: view, device: device)
            case .text(let pass):
                videoPipelineState = compileVideoPipeline(for: view, device: device)
                compileScene3DMaterialPipelines(pass.materialMaps, view: view, device: device)
            case .model(let pass):
                videoPipelineState = compileVideoPipeline(for: view, device: device)
                compileScene3DMaterialPipelines(pass.materialMaps, view: view, device: device)
            case .gaussianSplat:
                gaussianSplatPipelineState = compileGaussianSplatPipeline(for: view, device: device)
            case .particle(let pass):
                videoPipelineState = compileVideoPipeline(for: view, device: device)
                if let spriteSource = pass.spriteSource {
                    compilePipeline(for: spriteSource, role: .primary, view: view, device: device)
                }
            case .light:
                break
            case .transform(_, let child, _, _, _, _, _, _, _, _, _):
                compileScene3DSourcePipeline(child, view: view, device: device)
            }
        }

        private func compilePipeline(for source: PreviewPassSource, role: PipelineRole, view: MTKView, device: MTLDevice) {
            switch source {
            case .shader(let pass):
                let pipeline = compileShaderPipeline(source: pass.metalSource, for: view, device: device)
                switch role {
                case .primary:
                    primaryPipelineState = pipeline
                case .secondary:
                    secondaryPipelineState = pipeline
                }
                if pass.imageUniformSources.isEmpty == false {
                    videoPipelineState = compileVideoPipeline(for: view, device: device)
                    for source in pass.imageUniformSources {
                        guard let source else { continue }
                        compilePipeline(for: source, role: .secondary, view: view, device: device)
                    }
                }
            case .clear:
                break
            case .image:
                videoPipelineState = compileVideoPipeline(for: view, device: device)
            case .videoPlayer:
                videoPipelineState = compileVideoPipeline(for: view, device: device)
            case .coreImage(let pass):
                compilePipeline(for: pass.source, role: .primary, view: view, device: device)
                videoPipelineState = compileVideoPipeline(for: view, device: device)
                coreImageEffectPipelineState = compileCoreImageEffectPipeline(for: view, device: device)
            case .underwater(let pass):
                compilePipeline(for: pass.source, role: .primary, view: view, device: device)
                underwaterPipelineState = compileUnderwaterPipeline(for: view, device: device)
            case .mix(let primary, let secondary, _):
                compilePipeline(for: primary, role: .primary, view: view, device: device)
                compilePipeline(for: secondary, role: .secondary, view: view, device: device)
                compositePipelineState = compileCompositePipeline(for: view, device: device)
            case .transform(let pass):
                compilePipeline(for: pass.source, role: .primary, view: view, device: device)
                transformPipelineState = compileTransformPipeline(for: view, device: device)
            case .lineBatch:
                linePipelineState = compileLinePipeline(for: view, device: device)
            case .scene3DPrimitive:
                videoPipelineState = compileVideoPipeline(for: view, device: device)
            case .scene3DText:
                videoPipelineState = compileVideoPipeline(for: view, device: device)
            case .scene3DModel:
                videoPipelineState = compileVideoPipeline(for: view, device: device)
            case .scene3DGaussianSplat:
                gaussianSplatPipelineState = compileGaussianSplatPipeline(for: view, device: device)
            case .scene3DParticle(let pass):
                if let spriteSource = pass.spriteSource {
                    compilePipeline(for: spriteSource, role: .primary, view: view, device: device)
                }
                videoPipelineState = compileVideoPipeline(for: view, device: device)
            case .scene3DSource(let source):
                compileScene3DSourcePipeline(source, view: view, device: device)
            case .scene3DRender(let pass):
                videoPipelineState = compileVideoPipeline(for: view, device: device)
                underwaterPipelineState = compileUnderwaterPipeline(for: view, device: device)
                for source in pass.sources {
                    compileScene3DSourcePipeline(source, view: view, device: device)
                }
            case .transition(let pass):
                compilePipeline(for: pass.primary, role: .primary, view: view, device: device)
                compilePipeline(for: pass.secondary, role: .secondary, view: view, device: device)
                transitionPipelineState = compileTransitionPipeline(for: view, device: device)
            case .layers(let layers, _):
                for (index, layer) in layers.enumerated() {
                    compilePipeline(for: layer.source, role: index.isMultiple(of: 2) ? .secondary : .primary, view: view, device: device)
                }
                layerCompositePipelineState = compileLayerCompositePipeline(for: view, device: device)
                videoPipelineState = compileVideoPipeline(for: view, device: device)
            case .feedback(let pass):
                compilePipeline(for: pass.source, role: .primary, view: view, device: device)
                feedbackPipelineState = compileFeedbackPipeline(for: view, device: device)
                videoPipelineState = compileVideoPipeline(for: view, device: device)
            case .feedbackHistory:
                videoPipelineState = compileVideoPipeline(for: view, device: device)
            case .trail:
                trailPipelineState = compileTrailPipeline(for: view, device: device)
            case .circle:
                circlePipelineState = compileCirclePipeline(for: view, device: device)
            case .video:
                videoPipelineState = compileVideoPipeline(for: view, device: device)
            }
        }

        private func compileLayerCompositePipeline(for view: MTKView, device: MTLDevice) -> MTLRenderPipelineState? {
            do {
                let library = try device.makeLibrary(source: Self.layerShaderSource, options: nil)
                guard
                    let vertexFunction = library.makeFunction(name: "layerVertex"),
                    let fragmentFunction = library.makeFunction(name: "layerFragment")
                else {
                    return nil
                }

                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertexFunction
                descriptor.fragmentFunction = fragmentFunction
                descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                return nil
            }
        }

        private func compileFeedbackPipeline(for view: MTKView, device: MTLDevice) -> MTLRenderPipelineState? {
            do {
                let library = try device.makeLibrary(source: Self.feedbackShaderSource, options: nil)
                guard
                    let vertexFunction = library.makeFunction(name: "feedbackVertex"),
                    let fragmentFunction = library.makeFunction(name: "feedbackFragment")
                else {
                    return nil
                }

                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertexFunction
                descriptor.fragmentFunction = fragmentFunction
                descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                return nil
            }
        }

        private func compileVideoPipeline(for view: MTKView, device: MTLDevice) -> MTLRenderPipelineState? {
            do {
                let library = try device.makeLibrary(source: Self.videoShaderSource, options: nil)
                guard
                    let vertexFunction = library.makeFunction(name: "videoVertex"),
                    let fragmentFunction = library.makeFunction(name: "videoFragment")
                else {
                    return nil
                }

                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertexFunction
                descriptor.fragmentFunction = fragmentFunction
                descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
                descriptor.colorAttachments[0].isBlendingEnabled = true
                descriptor.colorAttachments[0].rgbBlendOperation = .add
                descriptor.colorAttachments[0].alphaBlendOperation = .add
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
                descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                return nil
            }
        }

        private func compileUnderwaterPipeline(for view: MTKView, device: MTLDevice) -> MTLRenderPipelineState? {
            do {
                let library = try device.makeLibrary(source: Self.underwaterShaderSource, options: nil)
                guard
                    let vertexFunction = library.makeFunction(name: "underwaterVertex"),
                    let fragmentFunction = library.makeFunction(name: "underwaterFragment")
                else {
                    return nil
                }

                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertexFunction
                descriptor.fragmentFunction = fragmentFunction
                descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                return nil
            }
        }

        private func compileTrailPipeline(for view: MTKView, device: MTLDevice) -> MTLRenderPipelineState? {
            do {
                let library = try device.makeLibrary(source: Self.trailShaderSource, options: nil)
                guard
                    let vertexFunction = library.makeFunction(name: "trailVertex"),
                    let fragmentFunction = library.makeFunction(name: "trailFragment")
                else {
                    return nil
                }

                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertexFunction
                descriptor.fragmentFunction = fragmentFunction
                descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                return nil
            }
        }

        private func compileCirclePipeline(for view: MTKView, device: MTLDevice) -> MTLRenderPipelineState? {
            do {
                let library = try device.makeLibrary(source: Self.circleShaderSource, options: nil)
                guard
                    let vertexFunction = library.makeFunction(name: "circleVertex"),
                    let fragmentFunction = library.makeFunction(name: "circleFragment")
                else {
                    return nil
                }

                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertexFunction
                descriptor.fragmentFunction = fragmentFunction
                descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                return nil
            }
        }

        private func compileGaussianSplatPipeline(for view: MTKView, device: MTLDevice) -> MTLRenderPipelineState? {
            do {
                let library = try device.makeLibrary(source: Self.gaussianSplatShaderSource, options: nil)
                guard
                    let vertexFunction = library.makeFunction(name: "gaussianSplatVertex"),
                    let fragmentFunction = library.makeFunction(name: "gaussianSplatFragment")
                else {
                    return nil
                }

                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertexFunction
                descriptor.fragmentFunction = fragmentFunction
                descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
                descriptor.colorAttachments[0].isBlendingEnabled = true
                descriptor.colorAttachments[0].rgbBlendOperation = .add
                descriptor.colorAttachments[0].alphaBlendOperation = .add
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                return nil
            }
        }

        private func makeRenderTexture(for view: MTKView) -> MTLTexture? {
            return makeRenderTexture(for: view.drawableSize)
        }

        private func makeRenderTexture(for drawableSize: CGSize) -> MTLTexture? {
            guard let device else { return nil }
            let width = max(Int(drawableSize.width), 1)
            let height = max(Int(drawableSize.height), 1)
            let key = "\(width)x\(height)"
            let nextIndex = renderTexturePoolIndices[key] ?? 0

            if let pooled = renderTexturePool[key], pooled.indices.contains(nextIndex) {
                renderTexturePoolIndices[key] = nextIndex + 1
                return pooled[nextIndex]
            }

            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                return nil
            }
            renderTexturePool[key, default: []].append(texture)
            renderTexturePoolIndices[key] = nextIndex + 1
            return texture
        }

        private func feedbackHistoryTexture(
            for nodeID: UUID,
            drawableSize: CGSize,
            commandBuffer: MTLCommandBuffer
        ) -> MTLTexture {
            if let existing = feedbackHistoryTextures[nodeID],
               existing.width == max(Int(drawableSize.width), 1),
               existing.height == max(Int(drawableSize.height), 1) {
                return existing
            }

            let texture = makeRenderTexture(for: drawableSize) ?? makeFallbackTexture()
            clearRenderTexture(texture, color: SIMD4<Float>(0, 0, 0, 0), commandBuffer: commandBuffer)
            feedbackHistoryTextures[nodeID] = texture
            return texture
        }

        private func makeFallbackTexture() -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: 1,
                height: 1,
                mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            return device!.makeTexture(descriptor: descriptor)!
        }

        private func makeDepthTexture(width: Int, height: Int) -> MTLTexture? {
            guard let device else { return nil }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .depth32Float,
                width: max(width, 1),
                height: max(height, 1),
                mipmapped: false
            )
            descriptor.usage = [.renderTarget]
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)
        }

        private func offscreenRenderPassDescriptor(for texture: MTLTexture, includeDepth: Bool = false) -> MTLRenderPassDescriptor? {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = texture
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            if includeDepth, let depthTexture = makeDepthTexture(width: texture.width, height: texture.height) {
                descriptor.depthAttachment.texture = depthTexture
                descriptor.depthAttachment.loadAction = .clear
                descriptor.depthAttachment.storeAction = .dontCare
                descriptor.depthAttachment.clearDepth = 1.0
            }
            return descriptor
        }

        private func texture(for pass: PreviewImagePass, device: MTLDevice) -> MTLTexture? {
            let fingerprint = pass.imageData.hashValue
            if let cached = imageTextures[pass.nodeID], cached.fingerprint == fingerprint {
                return cached.texture
            }

            let loader = MTKTextureLoader(device: device)
            let options: [MTKTextureLoader.Option: Any] = [
                .SRGB: false,
                .generateMipmaps: false
            ]

            guard let texture = try? loader.newTexture(data: pass.imageData, options: options) else {
                return nil
            }

            imageTextures[pass.nodeID] = (fingerprint, texture)
            return texture
        }

        private func texture(for pass: PreviewVideoPlayerPass) -> MTLTexture? {
            guard
                let cache = videoTextureCache,
                let pixelBuffer = VideoPlayerFrameRegistry.shared.pixelBuffer(for: pass.nodeID)
            else {
                return nil
            }

            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            var cvTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                0,
                &cvTexture
            )
            guard
                status == kCVReturnSuccess,
                let cvTexture,
                let texture = CVMetalTextureGetTexture(cvTexture)
            else {
                return nil
            }
            return texture
        }

        private func sceneRenderer(for pass: PreviewScene3DPrimitivePass, device: MTLDevice) -> SCNRenderer {
            if let existing = sceneRenderers[pass.nodeID] {
                return existing
            }

            let renderer = SCNRenderer(device: device, options: nil)
            renderer.autoenablesDefaultLighting = false
            sceneRenderers[pass.nodeID] = renderer
            return renderer
        }

        private func sceneRenderer(for pass: PreviewScene3DTextPass, device: MTLDevice) -> SCNRenderer {
            if let existing = sceneRenderers[pass.nodeID] {
                return existing
            }

            let renderer = SCNRenderer(device: device, options: nil)
            renderer.autoenablesDefaultLighting = false
            sceneRenderers[pass.nodeID] = renderer
            return renderer
        }

        private func sceneRenderer(for pass: PreviewScene3DModelPass, device: MTLDevice) -> SCNRenderer {
            if let existing = sceneRenderers[pass.nodeID] {
                return existing
            }

            let renderer = SCNRenderer(device: device, options: nil)
            renderer.autoenablesDefaultLighting = false
            sceneRenderers[pass.nodeID] = renderer
            return renderer
        }

        private func sceneRenderer(for pass: PreviewScene3DParticlePass, device: MTLDevice) -> SCNRenderer {
            if let existing = sceneRenderers[pass.nodeID] {
                return existing
            }

            let renderer = SCNRenderer(device: device, options: nil)
            renderer.autoenablesDefaultLighting = false
            sceneRenderers[pass.nodeID] = renderer
            return renderer
        }

        private func sceneRenderer(for pass: PreviewScene3DRenderPass, device: MTLDevice) -> SCNRenderer {
            if let existing = sceneRenderers[pass.nodeID] {
                return existing
            }

            let renderer = SCNRenderer(device: device, options: nil)
            renderer.autoenablesDefaultLighting = false
            sceneRenderers[pass.nodeID] = renderer
            return renderer
        }

        private func scene3DModel(
            for pass: PreviewScene3DModelPass,
            materialTextures: Scene3DMaterialTextures?
        ) -> SCNScene {
            let assetSignature = pass.settings.bookmarkData.hashValue
            let needsRebuild = modelScenes[pass.nodeID] == nil || modelSceneAssetSignatures[pass.nodeID] != assetSignature

            if needsRebuild {
                let scene = makeScene(for: pass, materialTextures: nil)
                modelScenes[pass.nodeID] = scene
                modelSceneAssetSignatures[pass.nodeID] = assetSignature
            }

            guard let scene = modelScenes[pass.nodeID] else {
                return makeScene(for: pass, materialTextures: materialTextures)
            }

            updateScene3DModelScene(
                scene,
                with: pass,
                materialTextures: materialTextures
            )
            return scene
        }

        private func scene3DMaterialTextures(
            from maps: PreviewScene3DMaterialMaps?,
            commandBuffer: MTLCommandBuffer,
            drawableSize: CGSize,
            currentTime: Float
        ) -> Scene3DMaterialTextures? {
            guard let maps else { return nil }

            func texture(for source: PreviewPassSource?) -> MTLTexture? {
                guard let source, let texture = makeRenderTexture(for: drawableSize) else {
                    return nil
                }
                renderPassSource(
                    source,
                    into: texture,
                    commandBuffer: commandBuffer,
                    drawableSize: drawableSize,
                    currentTime: currentTime,
                    role: .primary
                )
                return texture
            }

            let textures = Scene3DMaterialTextures(
                diffuse: texture(for: maps.diffuse),
                specular: texture(for: maps.specular),
                metallic: texture(for: maps.metallic),
                bump: texture(for: maps.bump),
                displacement: texture(for: maps.displacement)
            )

            if textures.diffuse == nil, textures.specular == nil, textures.metallic == nil, textures.bump == nil, textures.displacement == nil {
                return nil
            }
            return textures
        }

        private func makeScene(for pass: PreviewScene3DPrimitivePass, materialTextures: Scene3DMaterialTextures?) -> SCNScene {
            let scene = SCNScene()
            let settings = pass.settings
            scene.background.contents = NSColor.clear

            let cameraNode = SCNNode()
            cameraNode.name = "camera"
            cameraNode.camera = SCNCamera()
            cameraNode.position = SCNVector3(Float(settings.cameraPanX), Float(settings.cameraPanY), Float(settings.cameraDistance))
            cameraNode.eulerAngles = SCNVector3(
                Float(settings.cameraPitch * (.pi / 180.0)),
                Float(settings.cameraOrbit * (.pi / 180.0)),
                0
            )
            scene.rootNode.addChildNode(cameraNode)

            if let customLightNode = sceneLightNode(from: pass.light) {
                scene.rootNode.addChildNode(customLightNode)
            } else {
                let lightNode = SCNNode()
                lightNode.light = SCNLight()
                lightNode.light?.type = .omni
                lightNode.light?.intensity = CGFloat(settings.lightIntensity)
                lightNode.position = SCNVector3(2.5, 3.0, 5.0)
                scene.rootNode.addChildNode(lightNode)
            }

            let ambientNode = SCNNode()
            ambientNode.light = SCNLight()
            ambientNode.light?.type = .ambient
            ambientNode.light?.intensity = 180
            scene.rootNode.addChildNode(ambientNode)

            let geometryNode = SCNNode(geometry: geometry(for: settings, materialSettings: pass.material, materialTextures: materialTextures))
            geometryNode.position = SCNVector3(
                Float(settings.positionX),
                Float(settings.positionY),
                Float(settings.positionZ)
            )
            geometryNode.scale = SCNVector3(Float(settings.scale), Float(settings.scale), Float(settings.scale))
            geometryNode.eulerAngles = SCNVector3(
                Float(settings.rotationX * (.pi / 180.0)),
                Float(settings.rotationY * (.pi / 180.0)),
                Float(settings.rotationZ * (.pi / 180.0))
            )
            scene.rootNode.addChildNode(geometryNode)
            return scene
        }

        private func makeScene(
            for pass: PreviewScene3DRenderPass,
            commandBuffer: MTLCommandBuffer,
            drawableSize: CGSize,
            currentTime: Float
        ) -> SCNScene {
            let scene = SCNScene()
            scene.background.contents = NSColor.clear

            let cameraNode = SCNNode()
            cameraNode.name = "camera"
            cameraNode.camera = SCNCamera()
            cameraNode.position = SCNVector3(pass.cameraPanX, pass.cameraPanY, pass.cameraDistance)
            cameraNode.eulerAngles = SCNVector3(
                pass.cameraPitch * (.pi / 180.0),
                pass.cameraOrbit * (.pi / 180.0),
                0
            )
            scene.rootNode.addChildNode(cameraNode)

            if pass.sources.contains(where: sourceContainsLight) == false {
                let lightNode = SCNNode()
                lightNode.name = "defaultOmniLight"
                lightNode.light = SCNLight()
                lightNode.light?.type = .omni
                lightNode.light?.intensity = CGFloat(pass.defaultLightIntensity)
                lightNode.position = SCNVector3(2.5, 3.0, 5.0)
                scene.rootNode.addChildNode(lightNode)

                let ambientNode = SCNNode()
                ambientNode.name = "ambientLight"
                ambientNode.light = SCNLight()
                ambientNode.light?.type = .ambient
                ambientNode.light?.intensity = 180
                scene.rootNode.addChildNode(ambientNode)
            }

            for source in pass.sources {
                guard let node = sceneNode(
                    from: source,
                    commandBuffer: commandBuffer,
                    drawableSize: drawableSize,
                    currentTime: currentTime
                ) else {
                    continue
                }
                scene.rootNode.addChildNode(node)
            }

            return scene
        }

        private func makeScene(for pass: PreviewScene3DTextPass, materialTextures: Scene3DMaterialTextures?) -> SCNScene {
            let scene = SCNScene()
            let settings = pass.settings
            scene.background.contents = NSColor.clear

            let cameraNode = SCNNode()
            cameraNode.name = "camera"
            cameraNode.camera = SCNCamera()
            cameraNode.position = SCNVector3(Float(settings.cameraPanX), Float(settings.cameraPanY), Float(settings.cameraDistance))
            cameraNode.eulerAngles = SCNVector3(
                Float(settings.cameraPitch * (.pi / 180.0)),
                Float(settings.cameraOrbit * (.pi / 180.0)),
                0
            )
            scene.rootNode.addChildNode(cameraNode)

            if let customLightNode = sceneLightNode(from: pass.light) {
                scene.rootNode.addChildNode(customLightNode)
            } else {
                let lightNode = SCNNode()
                lightNode.light = SCNLight()
                lightNode.light?.type = .omni
                lightNode.light?.intensity = CGFloat(settings.lightIntensity)
                lightNode.position = SCNVector3(2.5, 3.0, 5.0)
                scene.rootNode.addChildNode(lightNode)
            }

            let ambientNode = SCNNode()
            ambientNode.light = SCNLight()
            ambientNode.light?.type = .ambient
            ambientNode.light?.intensity = 180
            scene.rootNode.addChildNode(ambientNode)

            let geometryNode = SCNNode(geometry: geometry(for: settings, materialSettings: pass.material, materialTextures: materialTextures))
            geometryNode.position = SCNVector3(
                Float(settings.positionX),
                Float(settings.positionY),
                Float(settings.positionZ)
            )
            geometryNode.scale = SCNVector3(Float(settings.scale), Float(settings.scale), Float(settings.scale))
            geometryNode.eulerAngles = SCNVector3(
                Float(settings.rotationX * (.pi / 180.0)),
                Float(settings.rotationY * (.pi / 180.0)),
                Float(settings.rotationZ * (.pi / 180.0))
            )
            scene.rootNode.addChildNode(geometryNode)
            return scene
        }

        private func makeScene(for pass: PreviewScene3DModelPass, materialTextures: Scene3DMaterialTextures?) -> SCNScene {
            let scene = SCNScene()
            let settings = pass.settings
            scene.background.contents = NSColor.clear

            let cameraNode = SCNNode()
            cameraNode.name = "camera"
            cameraNode.camera = SCNCamera()
            cameraNode.position = SCNVector3(Float(settings.cameraPanX), Float(settings.cameraPanY), Float(settings.cameraDistance))
            cameraNode.eulerAngles = SCNVector3(
                Float(settings.cameraPitch * (.pi / 180.0)),
                Float(settings.cameraOrbit * (.pi / 180.0)),
                0
            )
            scene.rootNode.addChildNode(cameraNode)

            if let customLightNode = sceneLightNode(from: pass.light) {
                customLightNode.name = "customSceneLight"
                scene.rootNode.addChildNode(customLightNode)
            } else {
                let lightNode = SCNNode()
                lightNode.name = "defaultOmniLight"
                lightNode.light = SCNLight()
                lightNode.light?.type = .omni
                lightNode.light?.intensity = CGFloat(settings.lightIntensity)
                lightNode.position = SCNVector3(2.5, 3.0, 5.0)
                scene.rootNode.addChildNode(lightNode)
            }

            let ambientNode = SCNNode()
            ambientNode.name = "ambientLight"
            ambientNode.light = SCNLight()
            ambientNode.light?.type = .ambient
            ambientNode.light?.intensity = 180
            scene.rootNode.addChildNode(ambientNode)

            if pass.light == nil {
                let keyLightNode = SCNNode()
                keyLightNode.name = "defaultKeyLight"
                keyLightNode.light = SCNLight()
                keyLightNode.light?.type = .directional
                keyLightNode.light?.intensity = CGFloat(settings.lightIntensity * 0.7)
                keyLightNode.eulerAngles = SCNVector3(-0.7, 0.7, 0)
                scene.rootNode.addChildNode(keyLightNode)
            }

            let modelTransformNode = SCNNode()
            modelTransformNode.name = "modelTransform"
            modelTransformNode.position = SCNVector3(
                Float(settings.positionX),
                Float(settings.positionY),
                Float(settings.positionZ)
            )
            modelTransformNode.eulerAngles = SCNVector3(
                Float(settings.rotationX * (.pi / 180.0)),
                Float(settings.rotationY * (.pi / 180.0)),
                Float(settings.rotationZ * (.pi / 180.0))
            )
            modelTransformNode.scale = SCNVector3(
                Float(settings.scale),
                Float(settings.scale),
                Float(settings.scale)
            )

            if let url = resolveSecurityScopedURL(from: settings.bookmarkData),
               let loadedModel = loadModelScene(from: url) {
                let loadedScene = loadedModel.scene
                let fittedNode = normalizedModelNode(from: loadedScene.rootNode)
                fittedNode.name = "modelContent"
                if let material = pass.material {
                    applyMaterialSettings(material, textures: materialTextures, to: fittedNode)
                }
                applyAnimations(to: fittedNode, settings: settings)
                modelTransformNode.addChildNode(fittedNode)
            } else if let url = resolveSecurityScopedURL(from: settings.bookmarkData) {
                let path = url.path
                if loggedModelLoadFailures.insert(path).inserted {
                    print("3D Model load failed: \(path)")
                }
            }

            scene.rootNode.addChildNode(modelTransformNode)
            return scene
        }

        private func makeScene(for pass: PreviewScene3DParticlePass, spriteImage: Any?) -> SCNScene {
            let scene = SCNScene()
            let settings = pass.settings
            scene.background.contents = NSColor.clear

            let cameraNode = SCNNode()
            cameraNode.name = "camera"
            cameraNode.camera = SCNCamera()
            cameraNode.position = SCNVector3(Float(settings.cameraPanX), Float(settings.cameraPanY), Float(settings.cameraDistance))
            cameraNode.eulerAngles = SCNVector3(
                Float(settings.cameraPitch * (.pi / 180.0)),
                Float(settings.cameraOrbit * (.pi / 180.0)),
                0
            )
            scene.rootNode.addChildNode(cameraNode)
            if pass.settings.spriteStyle == .fish {
                scene.rootNode.addChildNode(fishSchoolNode(for: pass, spriteImage: spriteImage, currentTime: 0, useCache: false))
            } else {
                scene.rootNode.addChildNode(particleNode(for: settings, spriteImage: spriteImage))
            }
            return scene
        }

        private func scene3DParticleScene(for pass: PreviewScene3DParticlePass, spriteImage: Any?, currentTime: Float) -> SCNScene {
            if pass.settings.spriteStyle == .fish {
                let scene = makeScene(for: pass, spriteImage: spriteImage)
                if let fishNode = scene.rootNode.childNodes.first(where: { $0.name == "fishSchool" }) {
                    updateFishSchoolNode(fishNode, settings: pass.settings, spriteImage: spriteImage, currentTime: currentTime)
                }
                return scene
            }

            let passSignature = "scene3dparticle:\(pass.nodeID.uuidString):\(pass.settings.shape.rawValue):\(pass.settings.spriteStyle.rawValue):\(pass.settings.blendMode.rawValue):\(pass.settings.scale):\(pass.settings.particleCount):\(pass.settings.birthRate):\(pass.settings.lifetime):\(pass.settings.speed):\(pass.settings.spread):\(pass.settings.boxWidth):\(pass.settings.boxHeight):\(pass.settings.boxDepth):\(pass.settings.size)"
            if let existing = particleScenes[pass.nodeID],
               particleSceneSignatures[pass.nodeID] == passSignature {
                updateParticleNode(in: existing, settings: pass.settings, spriteImage: spriteImage)
                return existing
            }

            let scene = makeScene(for: pass, spriteImage: spriteImage)
            particleScenes[pass.nodeID] = scene
            particleSceneSignatures[pass.nodeID] = passSignature
            return scene
        }

        private func sceneParticleNode(for pass: PreviewScene3DParticlePass, spriteImage: Any?, currentTime: Float) -> SCNNode {
            if pass.settings.spriteStyle == .fish {
                return fishSchoolNode(for: pass, spriteImage: spriteImage, currentTime: currentTime, useCache: true)
            }

            let signature = "sceneParticle:\(pass.nodeID.uuidString):\(pass.settings.shape.rawValue):\(pass.settings.spriteStyle.rawValue):\(pass.settings.blendMode.rawValue):\(pass.settings.scale):\(pass.settings.particleCount):\(pass.settings.birthRate):\(pass.settings.lifetime):\(pass.settings.speed):\(pass.settings.spread):\(pass.settings.boxWidth):\(pass.settings.boxHeight):\(pass.settings.boxDepth):\(pass.settings.size)"
            if let cached = sceneParticleNodes[pass.nodeID],
               cached.signature == signature {
                updateParticleNode(cached.node, settings: pass.settings, spriteImage: spriteImage)
                return cached.node
            }

            let node = particleNode(for: pass.settings, spriteImage: spriteImage)
            sceneParticleNodes[pass.nodeID] = (signature, node)
            return node
        }

        private func fishSchoolNode(for pass: PreviewScene3DParticlePass, spriteImage: Any?, currentTime: Float, useCache: Bool) -> SCNNode {
            let count = min(max(Int(pass.settings.particleCount.rounded()), 0), 2_000)
            let signature = "fishSchoolRig2:\(pass.nodeID.uuidString):\(count):\(pass.settings.blendMode.rawValue)"
            if useCache,
               let cached = sceneParticleNodes[pass.nodeID],
               cached.signature == signature {
                updateFishSchoolNode(cached.node, settings: pass.settings, spriteImage: spriteImage, currentTime: currentTime)
                return cached.node
            }

            let root = SCNNode()
            root.name = "fishSchool"

            for _ in 0..<count {
                let geometry = SCNPlane(width: 1.0, height: 0.42)
                let billboard = SCNNode()
                billboard.name = "fishBillboard"
                billboard.constraints = [SCNBillboardConstraint()]

                let sprite = SCNNode(geometry: geometry)
                sprite.name = "fishSprite"
                billboard.addChildNode(sprite)
                root.addChildNode(billboard)
            }

            if useCache {
                sceneParticleNodes[pass.nodeID] = (signature, root)
            }
            updateFishSchoolNode(root, settings: pass.settings, spriteImage: spriteImage, currentTime: currentTime)
            return root
        }

        private func updateFishSchoolNode(_ root: SCNNode, settings: Scene3DParticleNodeSettings, spriteImage: Any?, currentTime: Float) {
            updateParticleNodeTransform(root, settings: settings)

            let speed = max(0.0, Float(settings.speed))
            let time = speed <= 0.0001 ? 0.0 : currentTime * speed * 0.18
            let extent = max(0.35, Float(settings.spread) * 0.08)
            let depth = max(0.2, extent * 0.65)
            let size = max(0.001, Float(settings.size))
            let gravity = Float(settings.gravityY)
            let lifetime = max(0.1, Float(settings.lifetime))
            let columns = max(1, Int(settings.spriteSheetColumns.rounded()))
            let rows = max(1, Int(settings.spriteSheetRows.rounded()))
            let sheetCapacity = max(1, columns * rows)
            let sheetCount = min(sheetCapacity, max(1, Int(settings.spriteSheetCount.rounded())))
            let wobbleAmount = max(0.0, Float(settings.spriteWobble))
            let wobbleSpeed = max(0.0, Float(settings.spriteWobbleSpeed))

            for (index, billboard) in root.childNodes.enumerated() {
                let sprite = billboard.childNodes.first(where: { $0.name == "fishSprite" }) ?? billboard
                let fi = Float(index)
                let spriteIndex = settings.spriteSheetRandom
                    ? min(sheetCount - 1, Int(fishHash(fi + 307.0) * Float(sheetCount)))
                    : index % sheetCount
                let seedX = fishHash(fi + 11.1)
                let seedY = fishHash(fi + 29.7)
                let seedZ = fishHash(fi + 53.3)
                let seedSpeed = 0.55 + fishHash(fi + 91.9) * 0.75
                let phase = fishHash(fi + 133.7) * 6.2831855
                let age = speed <= 0.0001 ? 0.0 : fmod(max(0.0, time * seedSpeed + phase), lifetime) / lifetime

                let baseX = (seedX * 2.0 - 1.0) * extent
                let baseY = (seedY * 2.0 - 1.0) * extent * 0.45
                let baseZ = (seedZ * 2.0 - 1.0) * depth
                let drift = speed <= 0.0001 ? 0.0 : time * (0.25 + seedSpeed * 0.35)

                let x = wrapFishCoordinate(baseX + drift, limit: extent)
                let swim = sin(time * (0.8 + seedSpeed) + phase)
                let y = wrapFishCoordinate(baseY + swim * extent * 0.08 + gravity * age * age * 0.08, limit: max(0.2, extent * 0.6))
                let z = wrapFishCoordinate(baseZ + cos(time * (0.55 + seedSpeed) + phase) * depth * 0.15, limit: depth)

                billboard.position = SCNVector3(x, y, z)
                sprite.geometry?.firstMaterial = fishSchoolMaterial(
                    settings: settings,
                    spriteImage: spriteImage,
                    spriteIndex: spriteIndex
                )
                let sizeVariation = 0.72 + fishHash(fi + 211.0) * 0.55
                let flipX: Float = settings.spriteFlipX ? -1.0 : 1.0
                let flipY: Float = settings.spriteFlipY ? -1.0 : 1.0
                billboard.scale = SCNVector3(
                    size * sizeVariation * flipX,
                    size * sizeVariation * flipY,
                    size * sizeVariation
                )
                if wobbleAmount > 0.0001 {
                    let wobblePhase = phase + fishHash(fi + 421.0) * 6.2831855
                    let roll = sin(currentTime * wobbleSpeed + wobblePhase) * wobbleAmount * 0.65
                    sprite.eulerAngles = SCNVector3(0.0, 0.0, roll)
                } else {
                    sprite.eulerAngles = SCNVector3Zero
                }
                billboard.opacity = CGFloat(max(0.0, min(1.0, settings.alpha)))
            }
        }

        private func fishSchoolMaterial(settings: Scene3DParticleNodeSettings, spriteImage: Any?, spriteIndex: Int) -> SCNMaterial {
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = spriteImage ?? particleSpriteImage(style: .fish)
            material.diffuse.intensity = 1.0
            material.diffuse.wrapS = .clamp
            material.diffuse.wrapT = .clamp
            material.diffuse.contentsTransform = spriteSheetTransform(
                columns: max(1, Int(settings.spriteSheetColumns.rounded())),
                rows: max(1, Int(settings.spriteSheetRows.rounded())),
                spriteIndex: spriteIndex
            )
            material.multiply.contents = NSColor(
                red: settings.red,
                green: settings.green,
                blue: settings.blue,
                alpha: settings.alpha
            )
            material.isDoubleSided = true
            material.readsFromDepthBuffer = true
            material.writesToDepthBuffer = false
            material.transparency = CGFloat(max(0.0, min(1.0, settings.alpha)))
            switch settings.blendMode {
            case .alpha:
                material.blendMode = .alpha
            case .additive:
                material.blendMode = .add
            case .screen:
                material.blendMode = .screen
            }
            return material
        }

        private func spriteSheetTransform(columns: Int, rows: Int, spriteIndex: Int) -> SCNMatrix4 {
            let safeColumns = max(1, columns)
            let safeRows = max(1, rows)
            let clampedIndex = max(0, min(spriteIndex, safeColumns * safeRows - 1))
            let column = clampedIndex % safeColumns
            let row = clampedIndex / safeColumns
            let tileWidth = CGFloat(1.0 / Float(safeColumns))
            let tileHeight = CGFloat(1.0 / Float(safeRows))
            var transform = SCNMatrix4Identity
            transform.m11 = tileWidth
            transform.m22 = tileHeight
            transform.m41 = CGFloat(column) * tileWidth
            // Texture coordinates are bottom-origin; treat row 0 as the top row of the sheet.
            transform.m42 = 1.0 - CGFloat(row + 1) * tileHeight
            return transform
        }

        private func fishHash(_ value: Float) -> Float {
            let hashed = sin(Double(value) * 12.9898) * 43758.5453
            return Float(hashed - floor(hashed))
        }

        private func wrapFishCoordinate(_ value: Float, limit: Float) -> Float {
            guard limit > 0 else { return value }
            let span = limit * 2.0
            var wrapped = fmod(value + limit, span)
            if wrapped < 0 {
                wrapped += span
            }
            return wrapped - limit
        }

        private func sourceContainsLight(_ source: PreviewScene3DSource) -> Bool {
            switch source {
            case .light:
                return true
            case .transform(_, let child, _, _, _, _, _, _, _, _, _):
                return sourceContainsLight(child)
            case .primitive, .text, .model, .gaussianSplat, .particle:
                return false
            }
        }

        private func sceneNode(
            from source: PreviewScene3DSource,
            commandBuffer: MTLCommandBuffer,
            drawableSize: CGSize,
            currentTime: Float
        ) -> SCNNode? {
            switch source {
            case .gaussianSplat:
                return nil
            case .primitive(let pass):
                let materialTextures = scene3DMaterialTextures(
                    from: pass.materialMaps,
                    commandBuffer: commandBuffer,
                    drawableSize: drawableSize,
                    currentTime: currentTime
                )
                let node = SCNNode(geometry: geometry(
                    for: pass.settings,
                    materialSettings: pass.material,
                    materialTextures: materialTextures
                ))
                node.position = SCNVector3(
                    Float(pass.settings.positionX),
                    Float(pass.settings.positionY),
                    Float(pass.settings.positionZ)
                )
                node.scale = SCNVector3(
                    Float(pass.settings.scale),
                    Float(pass.settings.scale),
                    Float(pass.settings.scale)
                )
                node.eulerAngles = SCNVector3(
                    Float(pass.settings.rotationX * (.pi / 180.0)),
                    Float(pass.settings.rotationY * (.pi / 180.0)),
                    Float(pass.settings.rotationZ * (.pi / 180.0))
                )
                return node
            case .text(let pass):
                let materialTextures = scene3DMaterialTextures(
                    from: pass.materialMaps,
                    commandBuffer: commandBuffer,
                    drawableSize: drawableSize,
                    currentTime: currentTime
                )
                let node = SCNNode(geometry: geometry(
                    for: pass.settings,
                    materialSettings: pass.material,
                    materialTextures: materialTextures
                ))
                node.position = SCNVector3(
                    Float(pass.settings.positionX),
                    Float(pass.settings.positionY),
                    Float(pass.settings.positionZ)
                )
                node.scale = SCNVector3(
                    Float(pass.settings.scale),
                    Float(pass.settings.scale),
                    Float(pass.settings.scale)
                )
                node.eulerAngles = SCNVector3(
                    Float(pass.settings.rotationX * (.pi / 180.0)),
                    Float(pass.settings.rotationY * (.pi / 180.0)),
                    Float(pass.settings.rotationZ * (.pi / 180.0))
                )
                return node
            case .model(let pass):
                let materialTextures = scene3DMaterialTextures(
                    from: pass.materialMaps,
                    commandBuffer: commandBuffer,
                    drawableSize: drawableSize,
                    currentTime: currentTime
                )
                let modelScene = scene3DModel(for: pass, materialTextures: materialTextures)
                if let node = modelScene.rootNode.childNode(withName: "modelTransform", recursively: false)?.clone() {
                    applyAnimations(to: node, settings: pass.settings)
                    return node
                }
                return nil
            case .particle(let pass):
                let spriteImage = particleSpriteImage(
                    from: pass.spriteSource,
                    commandBuffer: commandBuffer,
                    drawableSize: drawableSize,
                    currentTime: currentTime
                )
                return sceneParticleNode(for: pass, spriteImage: spriteImage, currentTime: currentTime)
            case .light(let previewLight):
                return sceneLightNode(from: previewLight)
            case .transform(
                _,
                let childSource,
                let x,
                let y,
                let z,
                let scaleX,
                let scaleY,
                let scaleZ,
                let rotationDegreesX,
                let rotationDegreesY,
                let rotationDegreesZ
            ):
                guard let childNode = sceneNode(
                    from: childSource,
                    commandBuffer: commandBuffer,
                    drawableSize: drawableSize,
                    currentTime: currentTime
                ) else {
                    return nil
                }
                let wrapper = SCNNode()
                wrapper.position = SCNVector3(x, y, z)
                wrapper.scale = SCNVector3(scaleX, scaleY, scaleZ)
                wrapper.eulerAngles = SCNVector3(
                    rotationDegreesX * (.pi / 180.0),
                    rotationDegreesY * (.pi / 180.0),
                    rotationDegreesZ * (.pi / 180.0)
                )
                wrapper.addChildNode(childNode)
                return wrapper
            }
        }

        private func sceneLightNode(from previewLight: PreviewScene3DLight?) -> SCNNode? {
            guard let previewLight else { return nil }

            let settings = previewLight.settings
            let lightNode = SCNNode()
            let light = SCNLight()

            switch settings.type {
            case .omni:
                light.type = .omni
            case .directional:
                light.type = .directional
            case .spot:
                light.type = .spot
                light.spotInnerAngle = CGFloat(settings.innerSpotAngle)
                light.spotOuterAngle = CGFloat(settings.outerSpotAngle)
            case .ambient:
                light.type = .ambient
            }

            light.intensity = CGFloat(settings.intensity)
            light.color = NSColor(
                red: settings.red,
                green: settings.green,
                blue: settings.blue,
                alpha: settings.alpha
            )
            light.castsShadow = settings.castsShadow
            lightNode.light = light
            lightNode.position = SCNVector3(
                Float(settings.positionX),
                Float(settings.positionY),
                Float(settings.positionZ)
            )
            lightNode.eulerAngles = SCNVector3(
                Float(settings.rotationX * (.pi / 180.0)),
                Float(settings.rotationY * (.pi / 180.0)),
                Float(settings.rotationZ * (.pi / 180.0))
            )
            return lightNode
        }

        private func particleNode(for settings: Scene3DParticleNodeSettings, spriteImage: Any?) -> SCNNode {
            let node = SCNNode()
            node.name = "particleEmitter"
            updateParticleNodeTransform(node, settings: settings)

            let system = configuredParticleSystem(for: settings, spriteImage: spriteImage)
            node.addParticleSystem(system)
            return node
        }

        private func updateParticleNode(in scene: SCNScene, settings: Scene3DParticleNodeSettings, spriteImage: Any?) {
            guard let node = scene.rootNode.childNode(withName: "particleEmitter", recursively: true) else {
                return
            }
            updateParticleNode(node, settings: settings, spriteImage: spriteImage)
        }

        private func updateParticleNode(_ node: SCNNode, settings: Scene3DParticleNodeSettings, spriteImage: Any?) {
            updateParticleNodeTransform(node, settings: settings)
            guard let system = node.particleSystems?.first else {
                return
            }
            updateParticleSystem(system, settings: settings, spriteImage: spriteImage)
        }

        private func updateParticleNodeTransform(_ node: SCNNode, settings: Scene3DParticleNodeSettings) {
            node.position = SCNVector3(
                Float(settings.positionX),
                Float(settings.positionY),
                Float(settings.positionZ)
            )
            node.scale = SCNVector3(Float(settings.scale), Float(settings.scale), Float(settings.scale))
            node.eulerAngles = SCNVector3(
                Float(settings.rotationX * (.pi / 180.0)),
                Float(settings.rotationY * (.pi / 180.0)),
                Float(settings.rotationZ * (.pi / 180.0))
            )
        }

        private func configuredParticleSystem(for settings: Scene3DParticleNodeSettings, spriteImage: Any?) -> SCNParticleSystem {
            let system = SCNParticleSystem()
            updateParticleSystem(system, settings: settings, spriteImage: spriteImage)
            return system
        }

        private func updateParticleSystem(_ system: SCNParticleSystem, settings: Scene3DParticleNodeSettings, spriteImage: Any?) {
            let lifetime = max(0.05, settings.lifetime)
            let isFishSchool = settings.spriteStyle == .fish
            let isDustHaze = settings.spriteStyle == .dust
            let requestedSpeed = max(0.0, settings.speed)
            let isStopped = requestedSpeed <= 0.0001
            let velocity = requestedSpeed * (isFishSchool ? 0.035 : (isDustHaze ? 0.42 : 1.0))
            let desiredBirthRate = max(settings.birthRate, settings.particleCount / lifetime)
            system.birthRate = CGFloat((isFishSchool || isDustHaze) && isStopped ? 0.0 : desiredBirthRate)
            system.warmupDuration = CGFloat((isFishSchool || isStopped) ? 0.0 : min(lifetime, isDustHaze ? 12.0 : 8.0))
            system.particleLifeSpan = CGFloat(settings.lifetime)
            system.particleLifeSpanVariation = CGFloat(isStopped ? 0.0 : settings.lifetime * (isFishSchool ? 0.04 : (isDustHaze ? 0.55 : 0.35)))
            system.particleVelocity = CGFloat(velocity)
            system.particleVelocityVariation = CGFloat(isStopped ? 0.0 : velocity * (isFishSchool ? 0.05 : (isDustHaze ? 0.85 : 0.45)))
            system.speedFactor = liveIsRunning ? 1.0 : 0.0
            system.spreadingAngle = CGFloat(isStopped ? 0.0 : (isFishSchool ? min(settings.spread, 6.0) : settings.spread))
            system.particleSize = CGFloat(settings.size)
            system.particleSizeVariation = CGFloat(settings.size * (isFishSchool ? 0.04 : (isDustHaze ? 1.1 : 0.55)))
            system.particleColor = NSColor(
                red: settings.red,
                green: settings.green,
                blue: settings.blue,
                alpha: settings.alpha
            )
            system.particleColorVariation = isDustHaze ? SCNVector4(0.18, 0.12, 0.06, 0.18) : SCNVector4(0.08, 0.08, 0.08, 0.12)
            system.acceleration = isStopped ? SCNVector3Zero : SCNVector3(0, Float(settings.gravityY), 0)
            system.isAffectedByGravity = false
            system.loops = true
            system.isLocal = isFishSchool || isDustHaze
            system.birthLocation = isDustHaze ? .volume : .surface
            system.birthDirection = isDustHaze ? .random : .surfaceNormal
            system.particleImage = spriteImage ?? particleSpriteImage(style: settings.spriteStyle)

            switch settings.blendMode {
            case .alpha:
                system.blendMode = .alpha
            case .additive:
                system.blendMode = .additive
            case .screen:
                system.blendMode = .screen
            }

            if isFishSchool {
                system.emitterShape = nil
            } else {
                switch settings.shape {
                case .point:
                    system.emitterShape = nil
                case .sphere:
                    system.emitterShape = SCNSphere(radius: 0.5)
                case .box:
                    system.emitterShape = SCNBox(
                        width: max(0.01, CGFloat(settings.boxWidth)),
                        height: max(0.01, CGFloat(settings.boxHeight)),
                        length: max(0.01, CGFloat(settings.boxDepth)),
                        chamferRadius: 0.0
                    )
                }
            }
        }

        private func particleSpriteImage(
            from source: PreviewPassSource?,
            commandBuffer: MTLCommandBuffer,
            drawableSize: CGSize,
            currentTime: Float
        ) -> Any? {
            guard let source, let texture = makeRenderTexture(for: drawableSize) else {
                return nil
            }
            renderPassSource(
                source,
                into: texture,
                commandBuffer: commandBuffer,
                drawableSize: drawableSize,
                currentTime: currentTime,
                role: .primary
            )
            return texture
        }

        private func updateParticleSpriteImage(in scene: SCNScene?, spriteImage: Any?) {
            guard let spriteImage,
                  let system = scene?.rootNode
                    .childNode(withName: "particleEmitter", recursively: true)?
                    .particleSystems?
                    .first
            else {
                return
            }
            system.particleImage = spriteImage
        }

        private func particleSpriteImage(style: Scene3DParticleSpriteStyle = .glow) -> NSImage {
            switch style {
            case .glow:
                return glowParticleSpriteImage()
            case .fish:
                return fishParticleSpriteImage()
            case .dust:
                return dustParticleSpriteImage()
            }
        }

        private func glowParticleSpriteImage() -> NSImage {
            let size = NSSize(width: 32, height: 32)
            let image = NSImage(size: size)
            image.lockFocus()
            defer { image.unlockFocus() }

            NSColor.clear.setFill()
            NSRect(origin: .zero, size: size).fill()
            let path = NSBezierPath(ovalIn: NSRect(origin: .zero, size: size))
            let gradient = NSGradient(colors: [
                NSColor.white.withAlphaComponent(1.0),
                NSColor.white.withAlphaComponent(0.0)
            ])
            gradient?.draw(in: path, relativeCenterPosition: .zero)
            return image
        }

        private func dustParticleSpriteImage() -> NSImage {
            let size = NSSize(width: 48, height: 48)
            let image = NSImage(size: size)
            image.lockFocus()
            defer { image.unlockFocus() }

            NSColor.clear.setFill()
            NSRect(origin: .zero, size: size).fill()

            let bounds = NSRect(origin: .zero, size: size)
            let oval = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.0, dy: 1.0))
            let gradient = NSGradient(colors: [
                NSColor.white.withAlphaComponent(0.55),
                NSColor.white.withAlphaComponent(0.18),
                NSColor.white.withAlphaComponent(0.0)
            ])
            gradient?.draw(in: oval, relativeCenterPosition: NSPoint(x: -0.18, y: 0.16))

            for index in 0..<10 {
                let x = CGFloat((index * 17) % 43) + 2.0
                let y = CGFloat((index * 29) % 41) + 3.0
                let alpha = CGFloat(0.10 + Double(index % 4) * 0.035)
                NSColor.white.withAlphaComponent(alpha).setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 2.0, height: 2.0)).fill()
            }

            return image
        }

        private func fishParticleSpriteImage() -> NSImage {
            let size = NSSize(width: 64, height: 32)
            let image = NSImage(size: size)
            image.lockFocus()
            defer { image.unlockFocus() }

            NSColor.clear.setFill()
            NSRect(origin: .zero, size: size).fill()

            let body = NSBezierPath()
            body.move(to: NSPoint(x: 8, y: 16))
            body.curve(to: NSPoint(x: 42, y: 6), controlPoint1: NSPoint(x: 17, y: 4), controlPoint2: NSPoint(x: 32, y: 3))
            body.curve(to: NSPoint(x: 56, y: 16), controlPoint1: NSPoint(x: 49, y: 8), controlPoint2: NSPoint(x: 54, y: 13))
            body.curve(to: NSPoint(x: 42, y: 26), controlPoint1: NSPoint(x: 54, y: 19), controlPoint2: NSPoint(x: 49, y: 24))
            body.curve(to: NSPoint(x: 8, y: 16), controlPoint1: NSPoint(x: 32, y: 29), controlPoint2: NSPoint(x: 17, y: 28))
            body.close()

            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: 8, y: 16))
            tail.line(to: NSPoint(x: 0, y: 6))
            tail.line(to: NSPoint(x: 2, y: 16))
            tail.line(to: NSPoint(x: 0, y: 26))
            tail.close()

            NSColor.white.withAlphaComponent(0.95).setFill()
            body.fill()
            NSColor.white.withAlphaComponent(0.72).setFill()
            tail.fill()
            return image
        }

        private func resolveSecurityScopedURL(from bookmarkData: Data) -> URL? {
            guard bookmarkData.isEmpty == false else { return nil }
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                return nil
            }
            _ = url.startAccessingSecurityScopedResource()
            return url
        }

        private func gaussianSplatBuffer(for pass: PreviewScene3DGaussianSplatPass) -> (buffer: MTLBuffer, count: Int)? {
            guard let device else { return nil }
            let settings = pass.settings
            guard settings.bookmarkData.isEmpty == false || settings.panoramaImageData.isEmpty == false else {
                GaussianSplatLoadProgressStore.shared.update(
                    nodeID: pass.nodeID,
                    isLoading: false,
                    progress: 0.0,
                    message: "No splat loaded"
                )
                return nil
            }
            let assetSignature = gaussianSplatAssetSignature(for: settings)
            let sortSignature = gaussianSplatSortSignature(for: settings)
            if let cached = Self.gaussianSplatBuffers[pass.nodeID],
               cached.assetSignature == assetSignature,
               cached.sortSignature == sortSignature {
                GaussianSplatLoadProgressStore.shared.update(
                    nodeID: pass.nodeID,
                    isLoading: false,
                    progress: 1.0,
                    message: "Ready"
                )
                return (cached.buffer, cached.count)
            }

            let nodeID = pass.nodeID
            let jobSignature = "\(assetSignature)|\(sortSignature)"
            if Self.gaussianSplatLoadJobs[nodeID] != nil {
                if let cached = Self.gaussianSplatBuffers[nodeID],
                   cached.assetSignature == assetSignature {
                    GaussianSplatLoadProgressStore.shared.update(
                        nodeID: nodeID,
                        isLoading: false,
                        progress: 1.0,
                        message: "Updating splats..."
                    )
                    return (cached.buffer, cached.count)
                }
                return nil
            }

            if Self.gaussianSplatLoadJobs[nodeID] != jobSignature {
                let cachedVertices = Self.gaussianSplatBuffers[nodeID]?.assetSignature == assetSignature
                    ? Self.gaussianSplatBuffers[nodeID]?.vertices
                    : nil
                let url = cachedVertices == nil ? resolveSecurityScopedURL(from: settings.bookmarkData) : nil
                Self.gaussianSplatLoadJobs[nodeID] = jobSignature
                GaussianSplatLoadProgressStore.shared.update(
                    nodeID: nodeID,
                    isLoading: cachedVertices == nil,
                    progress: cachedVertices == nil ? 0.05 : 1.0,
                    message: cachedVertices == nil ? "Loading splat..." : "Resorting view..."
                )
                DispatchQueue.global(qos: .utility).async { [settings, assetSignature, sortSignature, jobSignature, nodeID, cachedVertices, url, device] in
                    let vertices: [GaussianSplatVertexGPU]
                    let isResortOnly = cachedVertices != nil
                    if let cachedVertices {
                        GaussianSplatLoadProgressStore.shared.update(
                            nodeID: nodeID,
                            isLoading: false,
                            progress: 1.0,
                            message: "Resorting view..."
                        )
                        vertices = cachedVertices
                    } else if settings.panoramaImageData.isEmpty == false,
                              let loadedVertices = Self.loadPanoramaPseudoSplat(
                                  from: settings.panoramaImageData,
                                  depthImageData: settings.panoramaDepthImageData,
                                  settings: settings
                              ),
                              loadedVertices.isEmpty == false {
                        GaussianSplatLoadProgressStore.shared.update(
                            nodeID: nodeID,
                            isLoading: true,
                            progress: 0.45,
                            message: "Built panorama splats..."
                        )
                        vertices = loadedVertices
                    } else if let url,
                              let loadedVertices = Self.loadGaussianSplatPLY(from: url, settings: settings),
                              loadedVertices.isEmpty == false {
                        GaussianSplatLoadProgressStore.shared.update(
                            nodeID: nodeID,
                            isLoading: true,
                            progress: 0.45,
                            message: "Loaded PLY splats..."
                        )
                        vertices = loadedVertices
                    } else {
                        DispatchQueue.main.async {
                            if Self.gaussianSplatLoadJobs[nodeID] == jobSignature {
                                Self.gaussianSplatLoadJobs[nodeID] = nil
                            }
                            GaussianSplatLoadProgressStore.shared.update(
                                nodeID: nodeID,
                                isLoading: false,
                                progress: 0.0,
                                message: "Load failed"
                            )
                        }
                        return
                    }

                    GaussianSplatLoadProgressStore.shared.update(
                        nodeID: nodeID,
                        isLoading: isResortOnly == false,
                        progress: isResortOnly ? 1.0 : 0.65,
                        message: isResortOnly ? "Resorting view..." : "Sorting splats..."
                    )
                    let sortedVertices = Self.gaussianSplatDepthSortedVertices(vertices, settings: settings)
                    GaussianSplatLoadProgressStore.shared.update(
                        nodeID: nodeID,
                        isLoading: isResortOnly == false,
                        progress: isResortOnly ? 1.0 : 0.85,
                        message: isResortOnly ? "Updating view..." : "Uploading splats..."
                    )
                    guard let buffer = device.makeBuffer(
                        bytes: sortedVertices,
                        length: MemoryLayout<GaussianSplatVertexGPU>.stride * sortedVertices.count,
                        options: .storageModeShared
                    ) else {
                        DispatchQueue.main.async {
                            if Self.gaussianSplatLoadJobs[nodeID] == jobSignature {
                                Self.gaussianSplatLoadJobs[nodeID] = nil
                            }
                            GaussianSplatLoadProgressStore.shared.update(
                                nodeID: nodeID,
                                isLoading: false,
                                progress: 0.0,
                                message: "Upload failed"
                            )
                        }
                        return
                    }

                    DispatchQueue.main.async { [weak self] in
                        guard Self.gaussianSplatLoadJobs[nodeID] == jobSignature else { return }
                        Self.gaussianSplatBuffers[nodeID] = GaussianSplatBufferCache(
                            assetSignature: assetSignature,
                            sortSignature: sortSignature,
                            vertices: vertices,
                            buffer: buffer,
                            count: sortedVertices.count
                        )
                        Self.gaussianSplatLoadJobs[nodeID] = nil
                        GaussianSplatLoadProgressStore.shared.update(
                            nodeID: nodeID,
                            isLoading: false,
                            progress: 1.0,
                            message: "Ready"
                        )
                        self?.view?.setNeedsDisplay(self?.view?.bounds ?? .zero)
                    }
                }
            }

            if let cached = Self.gaussianSplatBuffers[nodeID],
               cached.assetSignature == assetSignature {
                return (cached.buffer, cached.count)
            }
            return nil
        }

        private func gaussianSplatAssetSignature(for settings: Scene3DGaussianSplatNodeSettings) -> String {
            [
                settings.filename,
                dataSignature(settings.bookmarkData),
                dataSignature(settings.panoramaImageData),
                dataSignature(settings.panoramaDepthImageData),
                "\(Int(settings.maxSplats.rounded()))",
                "\(settings.panoramaRadius)",
                "\(settings.panoramaDepthScale)",
                "\(settings.autoCenter)",
                "\(settings.autoScale)"
            ].joined(separator: ":")
        }

        private func dataSignature(_ data: Data) -> String {
            guard data.isEmpty == false else { return "0:0" }

            var hash: UInt64 = 1469598103934665603
            let sampleStride = max(1, data.count / 4096)
            data.withUnsafeBytes { rawBuffer in
                guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }

                var index = 0
                while index < data.count {
                    hash ^= UInt64(bytes[index])
                    hash &*= 1099511628211
                    index += sampleStride
                }

                let tailStart = max(0, data.count - min(data.count, 256))
                for tailIndex in tailStart..<data.count {
                    hash ^= UInt64(bytes[tailIndex])
                    hash &*= 1099511628211
                }
            }
            return "\(data.count):\(hash)"
        }

        private func gaussianSplatSortSignature(for settings: Scene3DGaussianSplatNodeSettings) -> String {
            // Only camera/object rotations change draw ordering. Distance, pan, position,
            // and positive scale are uniform transforms that do not change relative depth,
            // so keeping them out prevents expensive 750k+ CPU resorts while animating.
            [
                settings.rotationX,
                settings.rotationY,
                settings.rotationZ,
                settings.cameraOrbit,
                settings.cameraPitch
            ]
            .map { String(format: "%.0f", $0.rounded()) }
            .joined(separator: ":")
        }

        nonisolated private static func gaussianSplatDepthSortedVertices(
            _ vertices: [GaussianSplatVertexGPU],
            settings: Scene3DGaussianSplatNodeSettings
        ) -> [GaussianSplatVertexGPU] {
            let scale = Float(max(0.001, settings.scale))
            let position = SIMD3<Float>(
                Float(settings.positionX),
                Float(settings.positionY),
                Float(settings.positionZ)
            )
            let rotationRadians = SIMD3<Float>(
                Float(settings.rotationX * .pi / 180.0),
                Float(settings.rotationY * .pi / 180.0),
                Float(settings.rotationZ * .pi / 180.0)
            )
            let cameraOrbitRadians = Float(settings.cameraOrbit * .pi / 180.0)
            let cameraPitchRadians = Float(settings.cameraPitch * .pi / 180.0)
            let cameraDistance = Float(settings.cameraDistance)

            return vertices
                .map { vertex in
                    (
                        vertex: vertex,
                        depth: gaussianSplatDepth(
                            for: vertex,
                            scale: scale,
                            position: position,
                            rotationRadians: rotationRadians,
                            cameraOrbitRadians: cameraOrbitRadians,
                            cameraPitchRadians: cameraPitchRadians,
                            cameraDistance: cameraDistance
                        )
                    )
                }
                .sorted { $0.depth > $1.depth }
                .map(\.vertex)
        }

        nonisolated private static func gaussianSplatDepth(
            for vertex: GaussianSplatVertexGPU,
            scale: Float,
            position: SIMD3<Float>,
            rotationRadians: SIMD3<Float>,
            cameraOrbitRadians: Float,
            cameraPitchRadians: Float,
            cameraDistance: Float
        ) -> Float {
            var p = SIMD3<Float>(vertex.position.x, vertex.position.y, vertex.position.z) * scale
            p += position
            p = rotateGaussianSplatX(p, rotationRadians.x)
            p = rotateGaussianSplatY(p, rotationRadians.y)
            p = rotateGaussianSplatZ(p, rotationRadians.z)
            p = rotateGaussianSplatY(p, cameraOrbitRadians)
            p = rotateGaussianSplatX(p, cameraPitchRadians)
            return p.z + cameraDistance
        }

        nonisolated private static func rotateGaussianSplatX(_ p: SIMD3<Float>, _ angle: Float) -> SIMD3<Float> {
            let s = sin(angle)
            let c = cos(angle)
            return SIMD3<Float>(p.x, p.y * c - p.z * s, p.y * s + p.z * c)
        }

        nonisolated private static func rotateGaussianSplatY(_ p: SIMD3<Float>, _ angle: Float) -> SIMD3<Float> {
            let s = sin(angle)
            let c = cos(angle)
            return SIMD3<Float>(p.x * c + p.z * s, p.y, -p.x * s + p.z * c)
        }

        nonisolated private static func rotateGaussianSplatZ(_ p: SIMD3<Float>, _ angle: Float) -> SIMD3<Float> {
            let s = sin(angle)
            let c = cos(angle)
            return SIMD3<Float>(p.x * c - p.y * s, p.x * s + p.y * c, p.z)
        }

        private struct RawRGBAImage: Sendable {
            let width: Int
            let height: Int
            let bytes: [UInt8]

            nonisolated init?(data: Data) {
                guard
                    let source = CGImageSourceCreateWithData(data as CFData, nil),
                    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
                else {
                    return nil
                }

                let width = image.width
                let height = image.height
                guard width > 0, height > 0 else { return nil }

                var bytes = [UInt8](repeating: 0, count: width * height * 4)
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                guard let context = CGContext(
                    data: &bytes,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                ) else {
                    return nil
                }

                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                self.width = width
                self.height = height
                self.bytes = bytes
            }

            nonisolated func colorAt(x: Int, y: Int) -> (r: Float, g: Float, b: Float, a: Float)? {
                guard x >= 0, y >= 0, x < width, y < height else { return nil }
                let offset = ((y * width) + x) * 4
                guard offset + 3 < bytes.count else { return nil }
                return (
                    Float(bytes[offset]) / 255.0,
                    Float(bytes[offset + 1]) / 255.0,
                    Float(bytes[offset + 2]) / 255.0,
                    Float(bytes[offset + 3]) / 255.0
                )
            }
        }

        nonisolated private static func loadPanoramaPseudoSplat(
            from imageData: Data,
            depthImageData: Data,
            settings: Scene3DGaussianSplatNodeSettings
        ) -> [GaussianSplatVertexGPU]? {
            guard let bitmap = RawRGBAImage(data: imageData) else { return nil }

            let width = bitmap.width
            let height = bitmap.height
            guard width > 1, height > 1 else { return nil }
            let depthBitmap = depthImageData.isEmpty ? nil : RawRGBAImage(data: depthImageData)

            let maxSplats = max(1, Int(settings.maxSplats.rounded()))
            let radius = Float(max(0.01, settings.panoramaRadius))
            let depthScale = Float(max(0.0, settings.panoramaDepthScale))
            var vertices: [GaussianSplatVertexGPU] = []
            vertices.reserveCapacity(maxSplats)

            func sampleColor(direction: SIMD3<Float>) -> (r: Float, g: Float, b: Float, a: Float)? {
                let normalized = simd_normalize(direction)
                let longitude = atan2(normalized.x, normalized.z)
                let latitude = asin(max(-1.0, min(1.0, normalized.y)))
                let u = (longitude / (2.0 * .pi)) + 0.5
                let v = 0.5 - (latitude / .pi)
                let x = min(width - 1, max(0, Int((u - floor(u)) * Float(width - 1))))
                let y = min(height - 1, max(0, Int(v * Float(height - 1))))
                return bitmap.colorAt(x: x, y: y)
            }

            func equirectangularUV(for direction: SIMD3<Float>) -> SIMD2<Float> {
                let normalized = simd_normalize(direction)
                let longitude = atan2(normalized.x, normalized.z)
                let latitude = asin(max(-1.0, min(1.0, normalized.y)))
                return SIMD2<Float>(
                    (longitude / (2.0 * .pi)) + 0.5,
                    0.5 - (latitude / .pi)
                )
            }

            func sampleDepth(direction: SIMD3<Float>) -> Float? {
                guard let depthBitmap else { return nil }
                let uv = equirectangularUV(for: direction)
                let depthWidth = depthBitmap.width
                let depthHeight = depthBitmap.height
                guard depthWidth > 1, depthHeight > 1 else { return nil }
                let x = min(depthWidth - 1, max(0, Int((uv.x - floor(uv.x)) * Float(depthWidth - 1))))
                let y = min(depthHeight - 1, max(0, Int(uv.y * Float(depthHeight - 1))))
                guard let color = depthBitmap.colorAt(x: x, y: y) else { return nil }
                let depth = color.r * 0.299 + color.g * 0.587 + color.b * 0.114
                return max(0.0, min(1.0, depth))
            }

            let faceCount = 6
            let gridSize = max(8, Int(sqrt(Double(maxSplats) / Double(faceCount))))
            let step = gridSize > 1 ? 2.0 / Float(gridSize - 1) : 2.0
            let faceScale = radius
            let splatScale = max(0.004, faceScale * step * 0.42)

            for face in 0..<faceCount {
                for yIndex in 0..<gridSize {
                    guard vertices.count < maxSplats else { break }
                    let rowJitter = (yIndex % 2 == 0) ? step * 0.25 : -step * 0.25
                    let yPlane = -1.0 + Float(yIndex) * step

                    for xIndex in 0..<gridSize {
                        guard vertices.count < maxSplats else { break }
                        let xPlane = -1.0 + Float(xIndex) * step + rowJitter
                        let clampedX = max(-1.0, min(1.0, xPlane))

                        let cubePoint: SIMD3<Float>
                        switch face {
                        case 0:
                            cubePoint = SIMD3<Float>(clampedX, yPlane, 1.0)
                        case 1:
                            cubePoint = SIMD3<Float>(-clampedX, yPlane, -1.0)
                        case 2:
                            cubePoint = SIMD3<Float>(-1.0, yPlane, clampedX)
                        case 3:
                            cubePoint = SIMD3<Float>(1.0, yPlane, -clampedX)
                        case 4:
                            cubePoint = SIMD3<Float>(clampedX, 1.0, -yPlane)
                        default:
                            cubePoint = SIMD3<Float>(clampedX, -1.0, yPlane)
                        }

                        guard let color = sampleColor(direction: cubePoint) else {
                            continue
                        }

                        let r = color.r
                        let g = color.g
                        let b = color.b
                        let a = color.a
                        let luma = r * 0.299 + g * 0.587 + b * 0.114
                        let maxChannel = max(r, max(g, b))
                        let minChannel = min(r, min(g, b))
                        let saturation = maxChannel > 0.0001 ? (maxChannel - minChannel) / maxChannel : 0.0
                        let horizonWeight = 1.0 - min(abs(cubePoint.y) * 0.85, 1.0)
                        let waterHaze = min(max((b + g) * 0.5 - r * 0.35, 0.0), 1.0)
                        let heuristicDepth = 0.25
                            + 0.35 * horizonWeight
                            + 0.25 * (1.0 - saturation)
                            + 0.15 * waterHaze
                            + 0.10 * luma
                        let depth = sampleDepth(direction: cubePoint) ?? heuristicDepth
                        let depthStrength: Float = depthBitmap == nil ? 0.06 : 0.16
                        let inwardDepth = min(0.65, depthScale * depthStrength * depth)
                        let direction = simd_normalize(cubePoint)
                        let position = (cubePoint * faceScale) - (direction * faceScale * inwardDepth)

                        vertices.append(GaussianSplatVertexGPU(
                            position: SIMD4<Float>(position.x, position.y, position.z, 1.0),
                            color: SIMD4<Float>(r, g, b, max(0.05, a)),
                            scale: SIMD4<Float>(splatScale, splatScale, splatScale, 0.0),
                            rotation: SIMD4<Float>(1.0, 0.0, 0.0, 0.0)
                        ))
                    }
                }
            }

            return vertices
        }

        nonisolated private static func loadGaussianSplatPLY(from url: URL, settings: Scene3DGaussianSplatNodeSettings) -> [GaussianSplatVertexGPU]? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            guard let headerRange = data.range(of: Data("end_header\n".utf8)) ?? data.range(of: Data("end_header\r\n".utf8)) else { return nil }
            guard let header = String(data: data[..<headerRange.upperBound], encoding: .utf8) else { return nil }
            let lines = header.components(separatedBy: .newlines)
            let isASCII = lines.contains { $0.contains("format ascii") }
            let isBinaryLittleEndian = lines.contains { $0.contains("format binary_little_endian") }
            guard isASCII || isBinaryLittleEndian else { return nil }

            var vertexCount = 0
            var properties: [(name: String, type: String)] = []
            var readingVertex = false
            for line in lines {
                let parts = line.split(separator: " ").map(String.init)
                guard parts.isEmpty == false else { continue }
                if parts.count >= 3, parts[0] == "element", parts[1] == "vertex" {
                    vertexCount = Int(parts[2]) ?? 0
                    readingVertex = true
                    continue
                }
                if parts.count >= 2, parts[0] == "element", parts[1] != "vertex" {
                    readingVertex = false
                    continue
                }
                if readingVertex, parts.count >= 3, parts[0] == "property", parts[1] != "list" {
                    properties.append((parts[2], parts[1]))
                }
            }
            guard vertexCount > 0, properties.isEmpty == false else { return nil }

            let maxSplats = min(vertexCount, max(1, Int(settings.maxSplats.rounded())))
            var vertices: [GaussianSplatVertexGPU] = []
            vertices.reserveCapacity(maxSplats)

            func sampledPLYIndex(_ sample: Int) -> Int {
                guard maxSplats < vertexCount else { return sample }
                let fraction = Double(sample) / Double(maxSplats)
                return min(vertexCount - 1, Int((fraction * Double(vertexCount)).rounded(.down)))
            }

            if isASCII {
                guard let body = String(data: data[headerRange.upperBound...], encoding: .utf8) else { return nil }
                var sample = 0
                var nextIndex = sampledPLYIndex(sample)
                for (index, line) in body.components(separatedBy: .newlines).enumerated() where index < vertexCount {
                    guard index == nextIndex else { continue }
                    let values = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { Float($0) ?? 0 }
                    if let vertex = gaussianSplatVertex(from: values, properties: properties) {
                        vertices.append(vertex)
                    }
                    sample += 1
                    guard sample < maxSplats else { break }
                    nextIndex = sampledPLYIndex(sample)
                }
            } else {
                let rowStride = properties.reduce(0) { $0 + plyByteSize(for: $1.type) }
                guard rowStride > 0, data.count >= headerRange.upperBound + rowStride * vertexCount else { return nil }
                for sample in 0..<maxSplats {
                    let index = sampledPLYIndex(sample)
                    var offset = headerRange.upperBound + index * rowStride
                    var values: [Float] = []
                    values.reserveCapacity(properties.count)
                    for property in properties {
                        values.append(readPLYScalar(data: data, offset: offset, type: property.type))
                        offset += plyByteSize(for: property.type)
                    }
                    if let vertex = gaussianSplatVertex(from: values, properties: properties) {
                        vertices.append(vertex)
                    }
                }
            }

            if settings.autoCenter || settings.autoScale {
                normalizeGaussianSplatVertices(&vertices, autoCenter: settings.autoCenter, autoScale: settings.autoScale)
            }
            return vertices
        }

        nonisolated private static func gaussianSplatVertex(from values: [Float], properties: [(name: String, type: String)]) -> GaussianSplatVertexGPU? {
            func value(_ name: String) -> Float? {
                guard let index = properties.firstIndex(where: { $0.name == name }), values.indices.contains(index) else { return nil }
                return values[index]
            }
            guard let x = value("x"), let y = value("y"), let z = value("z") else { return nil }
            let shScale: Float = 0.2820947918
            let r = value("red").map { min(max($0 / 255.0, 0.0), 1.0) } ?? min(max(0.5 + shScale * (value("f_dc_0") ?? 1.5), 0.0), 1.0)
            let g = value("green").map { min(max($0 / 255.0, 0.0), 1.0) } ?? min(max(0.5 + shScale * (value("f_dc_1") ?? 1.5), 0.0), 1.0)
            let b = value("blue").map { min(max($0 / 255.0, 0.0), 1.0) } ?? min(max(0.5 + shScale * (value("f_dc_2") ?? 1.5), 0.0), 1.0)
            let alpha = value("opacity").map { 1.0 / (1.0 + exp(-$0)) } ?? 1.0
            let sx = value("scale_0").map { min(max(exp($0), 0.0001), 0.25) } ?? 0.01
            let sy = value("scale_1").map { min(max(exp($0), 0.0001), 0.25) } ?? sx
            let sz = value("scale_2").map { min(max(exp($0), 0.0001), 0.25) } ?? sx
            let qw = value("rot_0") ?? 1.0
            let qx = value("rot_1") ?? 0.0
            let qy = value("rot_2") ?? 0.0
            let qz = value("rot_3") ?? 0.0
            return GaussianSplatVertexGPU(
                position: SIMD4<Float>(x, y, z, 1.0),
                color: SIMD4<Float>(r, g, b, min(max(alpha, 0.02), 1.0)),
                scale: SIMD4<Float>(sx, sy, sz, 0.0),
                rotation: SIMD4<Float>(qw, qx, qy, qz)
            )
        }

        nonisolated private static func normalizeGaussianSplatVertices(_ vertices: inout [GaussianSplatVertexGPU], autoCenter: Bool, autoScale: Bool) {
            guard vertices.isEmpty == false else { return }
            var minP = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var maxP = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for vertex in vertices {
                let p = SIMD3<Float>(vertex.position.x, vertex.position.y, vertex.position.z)
                minP = simd.min(minP, p)
                maxP = simd.max(maxP, p)
            }
            let center = (minP + maxP) * 0.5
            let extent = max(maxP.x - minP.x, max(maxP.y - minP.y, maxP.z - minP.z))
            let normalizationScale: Float = autoScale ? (2.0 / max(extent, 0.0001)) : 1.0
            for index in vertices.indices {
                var p = SIMD3<Float>(vertices[index].position.x, vertices[index].position.y, vertices[index].position.z)
                if autoCenter { p -= center }
                p *= normalizationScale
                vertices[index].position.x = p.x
                vertices[index].position.y = p.y
                vertices[index].position.z = p.z
                vertices[index].scale.x *= normalizationScale
                vertices[index].scale.y *= normalizationScale
                vertices[index].scale.z *= normalizationScale
            }
        }

        nonisolated private static func plyByteSize(for type: String) -> Int {
            switch type {
            case "char", "uchar", "int8", "uint8": return 1
            case "short", "ushort", "int16", "uint16": return 2
            case "int", "uint", "float", "int32", "uint32", "float32": return 4
            case "double", "float64": return 8
            default: return 4
            }
        }

        nonisolated private static func readPLYScalar(data: Data, offset: Int, type: String) -> Float {
            switch type {
            case "char", "int8":
                guard let value = readPLYUInt8(data: data, offset: offset) else { return 0 }
                return Float(Int8(bitPattern: value))
            case "uchar", "uint8":
                guard let value = readPLYUInt8(data: data, offset: offset) else { return 0 }
                return Float(value)
            case "short", "int16":
                guard let value = readPLYUInt16(data: data, offset: offset) else { return 0 }
                return Float(Int16(bitPattern: value))
            case "ushort", "uint16":
                guard let value = readPLYUInt16(data: data, offset: offset) else { return 0 }
                return Float(value)
            case "int", "int32":
                guard let value = readPLYUInt32(data: data, offset: offset) else { return 0 }
                return Float(Int32(bitPattern: value))
            case "uint", "uint32":
                guard let value = readPLYUInt32(data: data, offset: offset) else { return 0 }
                return Float(value)
            case "double", "float64":
                guard let value = readPLYUInt64(data: data, offset: offset) else { return 0 }
                return Float(Double(bitPattern: value))
            default:
                guard let value = readPLYUInt32(data: data, offset: offset) else { return 0 }
                return Float(bitPattern: value)
            }
        }

        nonisolated private static func readPLYUInt8(data: Data, offset: Int) -> UInt8? {
            guard offset >= 0, offset < data.count else { return nil }
            return data[offset]
        }

        nonisolated private static func readPLYUInt16(data: Data, offset: Int) -> UInt16? {
            guard offset >= 0, offset + 1 < data.count else { return nil }
            return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }

        nonisolated private static func readPLYUInt32(data: Data, offset: Int) -> UInt32? {
            guard offset >= 0, offset + 3 < data.count else { return nil }
            return UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
        }

        nonisolated private static func readPLYUInt64(data: Data, offset: Int) -> UInt64? {
            guard offset >= 0, offset + 7 < data.count else { return nil }
            var value: UInt64 = 0
            for byteOffset in 0..<8 {
                value |= UInt64(data[offset + byteOffset]) << UInt64(byteOffset * 8)
            }
            return value
        }

        private func normalizedModelNode(from sourceNode: SCNNode) -> SCNNode {
            let container = SCNNode()
            let scaleNode = SCNNode()
            let offsetNode = sourceNode.clone()
            applyFallbackModelMaterials(to: offsetNode)

            scaleNode.addChildNode(offsetNode)
            container.addChildNode(scaleNode)

            if let (minBound, maxBound) = modelBounds(for: offsetNode) {
                let size = SCNVector3(
                    maxBound.x - minBound.x,
                    maxBound.y - minBound.y,
                    maxBound.z - minBound.z
                )
                let maxDimension = Float(max(size.x, max(size.y, size.z)))
                let center = SCNVector3(
                    (minBound.x + maxBound.x) * 0.5,
                    (minBound.y + maxBound.y) * 0.5,
                    (minBound.z + maxBound.z) * 0.5
                )

                offsetNode.position = SCNVector3(-center.x, -center.y, -center.z)

                if maxDimension.isFinite, maxDimension > 0.0001 {
                    let fitScale = Float(4.0) / maxDimension
                    scaleNode.scale = SCNVector3(fitScale, fitScale, fitScale)
                }
            }

            return container
        }

        private struct LoadedModelScene {
            let scene: SCNScene
            let source: SCNSceneSource?
        }

        private func updateScene3DModelScene(
            _ scene: SCNScene,
            with pass: PreviewScene3DModelPass,
            materialTextures: Scene3DMaterialTextures?
        ) {
            let settings = pass.settings

            if let cameraNode = scene.rootNode.childNode(withName: "camera", recursively: true) {
                cameraNode.position = SCNVector3(
                    Float(settings.cameraPanX),
                    Float(settings.cameraPanY),
                    Float(settings.cameraDistance)
                )
                cameraNode.eulerAngles = SCNVector3(
                    Float(settings.cameraPitch * (.pi / 180.0)),
                    Float(settings.cameraOrbit * (.pi / 180.0)),
                    0
                )
            }

            scene.rootNode.childNode(withName: "defaultOmniLight", recursively: false)?.removeFromParentNode()
            scene.rootNode.childNode(withName: "ambientLight", recursively: false)?.removeFromParentNode()
            scene.rootNode.childNode(withName: "defaultKeyLight", recursively: false)?.removeFromParentNode()
            scene.rootNode.childNode(withName: "customSceneLight", recursively: false)?.removeFromParentNode()

            if let customLightNode = sceneLightNode(from: pass.light) {
                customLightNode.name = "customSceneLight"
                scene.rootNode.addChildNode(customLightNode)
            } else {
                let lightNode = SCNNode()
                lightNode.name = "defaultOmniLight"
                lightNode.light = SCNLight()
                lightNode.light?.type = .omni
                lightNode.light?.intensity = CGFloat(settings.lightIntensity)
                lightNode.position = SCNVector3(2.5, 3.0, 5.0)
                scene.rootNode.addChildNode(lightNode)

                let ambientNode = SCNNode()
                ambientNode.name = "ambientLight"
                ambientNode.light = SCNLight()
                ambientNode.light?.type = .ambient
                ambientNode.light?.intensity = 180
                scene.rootNode.addChildNode(ambientNode)

                let keyLightNode = SCNNode()
                keyLightNode.name = "defaultKeyLight"
                keyLightNode.light = SCNLight()
                keyLightNode.light?.type = .directional
                keyLightNode.light?.intensity = CGFloat(settings.lightIntensity * 0.7)
                keyLightNode.eulerAngles = SCNVector3(-0.7, 0.7, 0)
                scene.rootNode.addChildNode(keyLightNode)
            }

            if let modelTransformNode = scene.rootNode.childNode(withName: "modelTransform", recursively: false) {
                modelTransformNode.position = SCNVector3(
                    Float(settings.positionX),
                    Float(settings.positionY),
                    Float(settings.positionZ)
                )
                modelTransformNode.eulerAngles = SCNVector3(
                    Float(settings.rotationX * (.pi / 180.0)),
                    Float(settings.rotationY * (.pi / 180.0)),
                    Float(settings.rotationZ * (.pi / 180.0))
                )
                modelTransformNode.scale = SCNVector3(
                    Float(settings.scale),
                    Float(settings.scale),
                    Float(settings.scale)
                )

                if let modelContentNode = modelTransformNode.childNode(withName: "modelContent", recursively: false),
                   let material = pass.material {
                    applyMaterialSettings(material, textures: materialTextures, to: modelContentNode)
                }

                if let modelContentNode = modelTransformNode.childNode(withName: "modelContent", recursively: false) {
                    applyAnimations(to: modelContentNode, settings: settings)
                }
            }
        }

        private func loadModelScene(from url: URL) -> LoadedModelScene? {
            let options: [SCNSceneSource.LoadingOption: Any] = [
                .checkConsistency: false,
                .createNormalsIfAbsent: true,
                .animationImportPolicy: SCNSceneSource.AnimationImportPolicy.playRepeatedly,
                .assetDirectoryURLs: [url.deletingLastPathComponent()]
            ]

            do {
                let modelData = try Data(contentsOf: url)
                if let source = SCNSceneSource(data: modelData, options: options) {
                    return try LoadedModelScene(scene: source.scene(options: options), source: source)
                }
            } catch {
                print("3D Model data load failed for \(url.lastPathComponent): \(error.localizedDescription)")
            }

            do {
                if let source = SCNSceneSource(url: url, options: options) {
                    return try LoadedModelScene(scene: source.scene(options: options), source: source)
                }
            } catch {
                print("3D Model SceneKit load failed for \(url.lastPathComponent): \(error.localizedDescription)")
            }

            return nil
        }

        private func applyAnimations(
            to node: SCNNode,
            settings: Scene3DModelNodeSettings
        ) {
            let shouldPlay = settings.animationPlay >= 0.5
            let clipStart = max(0.0, min(1.0, settings.animationClipStart))
            let clipEnd = max(clipStart, min(1.0, settings.animationClipEnd))
            let clipSpan = max(clipEnd - clipStart, 0.0001)

            func configure(player: SCNAnimationPlayer) {
                let playerID = ObjectIdentifier(player)
                let baseDuration = animationPlayerBaseDurations[playerID] ?? max(player.animation.duration, 0.0001)
                animationPlayerBaseDurations[playerID] = baseDuration

                player.animation.timeOffset = baseDuration * clipStart
                player.animation.duration = baseDuration * clipSpan
                player.animation.repeatCount = settings.animationLoops ? .greatestFiniteMagnitude : 0
                player.speed = CGFloat(settings.animationSpeed)
                player.paused = !shouldPlay

                if shouldPlay {
                    player.play()
                } else {
                    player.stop()
                }
            }

            func configure(animation: CAAnimation) {
                let animationID = ObjectIdentifier(animation)
                let baseDuration = fallbackAnimationBaseDurations[animationID] ?? max(animation.duration, 0.0001)
                fallbackAnimationBaseDurations[animationID] = baseDuration

                animation.timeOffset = baseDuration * clipStart
                animation.duration = baseDuration * clipSpan
                animation.speed = Float(settings.animationSpeed)
                animation.repeatCount = settings.animationLoops ? .greatestFiniteMagnitude : 0
                animation.repeatDuration = settings.animationLoops ? .greatestFiniteMagnitude : (baseDuration * clipSpan)
                animation.isRemovedOnCompletion = false
                animation.fillMode = .both
            }

            func configureAnimations(on animatedNode: SCNNode) {
                animatedNode.isPaused = !shouldPlay
                for key in animatedNode.animationKeys {
                    if let player = animatedNode.animationPlayer(forKey: key) {
                        configure(player: player)
                    } else if let animation = animatedNode.animation(forKey: key) {
                        configure(animation: animation)
                    }
                }
            }

            configureAnimations(on: node)
            node.enumerateChildNodes { child, _ in
                configureAnimations(on: child)
            }
        }

        private func modelBounds(for rootNode: SCNNode) -> (SCNVector3, SCNVector3)? {
            var hasBounds = false
            var minBound = SCNVector3(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
            var maxBound = SCNVector3(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)

            rootNode.enumerateChildNodes { node, _ in
                guard node.geometry != nil else { return }
                let (localMin, localMax) = node.boundingBox
                let corners = [
                    SCNVector3(localMin.x, localMin.y, localMin.z),
                    SCNVector3(localMin.x, localMin.y, localMax.z),
                    SCNVector3(localMin.x, localMax.y, localMin.z),
                    SCNVector3(localMin.x, localMax.y, localMax.z),
                    SCNVector3(localMax.x, localMin.y, localMin.z),
                    SCNVector3(localMax.x, localMin.y, localMax.z),
                    SCNVector3(localMax.x, localMax.y, localMin.z),
                    SCNVector3(localMax.x, localMax.y, localMax.z)
                ]

                for corner in corners {
                    let converted = node.convertPosition(corner, to: rootNode)
                    minBound.x = min(minBound.x, converted.x)
                    minBound.y = min(minBound.y, converted.y)
                    minBound.z = min(minBound.z, converted.z)
                    maxBound.x = max(maxBound.x, converted.x)
                    maxBound.y = max(maxBound.y, converted.y)
                    maxBound.z = max(maxBound.z, converted.z)
                    hasBounds = true
                }
            }

            return hasBounds ? (minBound, maxBound) : nil
        }

        private func applyFallbackModelMaterials(to rootNode: SCNNode) {
            rootNode.enumerateChildNodes { node, _ in
                guard let geometry = node.geometry else { return }

                if geometry.materials.isEmpty {
                    let material = SCNMaterial()
                    material.diffuse.contents = NSColor(white: 0.86, alpha: 1.0)
                    material.ambient.contents = NSColor(white: 0.42, alpha: 1.0)
                    material.specular.contents = NSColor(white: 0.18, alpha: 1.0)
                    material.emission.contents = NSColor(white: 0.05, alpha: 1.0)
                    material.lightingModel = .blinn
                    material.isDoubleSided = true
                    material.locksAmbientWithDiffuse = true
                    geometry.materials = [material]
                    return
                }

                geometry.materials = geometry.materials.map { existing in
                    let material = (existing.copy() as? SCNMaterial) ?? existing
                    material.lightingModel = .blinn
                    material.isDoubleSided = true
                    material.locksAmbientWithDiffuse = true

                    if material.ambient.contents == nil {
                        material.ambient.contents = NSColor(white: 0.42, alpha: 1.0)
                    }
                    if material.specular.contents == nil {
                        material.specular.contents = NSColor(white: 0.18, alpha: 1.0)
                    }

                    return material
                }
            }
        }

        private func applyMaterialSettings(
            _ settings: Scene3DMaterialNodeSettings,
            textures: Scene3DMaterialTextures? = nil,
            to material: SCNMaterial
        ) {
            material.diffuse.contents = NSColor(
                red: settings.red,
                green: settings.green,
                blue: settings.blue,
                alpha: settings.alpha
            )
            material.metalness.contents = settings.metallic
            material.roughness.contents = settings.roughness
            material.emission.contents = NSColor(
                red: settings.red * settings.emission,
                green: settings.green * settings.emission,
                blue: settings.blue * settings.emission,
                alpha: 1.0
            )
            material.isDoubleSided = settings.doubleSided
            material.lightingModel = .physicallyBased

            if let diffuse = textures?.diffuse {
                material.diffuse.contents = diffuse
            }
            if let specular = textures?.specular {
                material.specular.contents = specular
                material.lightingModel = .blinn
            }
            if let metallic = textures?.metallic {
                material.metalness.contents = metallic
            }
            if let bump = textures?.bump {
                material.normal.contents = bump
                material.normal.intensity = 1.2
            }
            if let displacement = textures?.displacement {
                material.displacement.contents = displacement
                material.displacement.intensity = 0.15
            }
        }

        private func applyMaterialSettings(
            _ settings: Scene3DMaterialNodeSettings,
            textures: Scene3DMaterialTextures? = nil,
            to rootNode: SCNNode
        ) {
            rootNode.enumerateChildNodes { node, _ in
                guard let geometry = node.geometry else { return }
                let baseMaterials = geometry.materials.isEmpty ? [SCNMaterial()] : geometry.materials
                geometry.materials = baseMaterials.map { existing in
                    let material = (existing.copy() as? SCNMaterial) ?? existing
                    applyMaterialSettings(settings, textures: textures, to: material)
                    return material
                }
            }
        }

        private func geometry(
            for settings: Scene3DPrimitiveNodeSettings,
            materialSettings: Scene3DMaterialNodeSettings,
            materialTextures: Scene3DMaterialTextures?
        ) -> SCNGeometry {
            let geometry: SCNGeometry
            switch settings.primitive {
            case .box:
                geometry = SCNBox(width: 1.3, height: 1.3, length: 1.3, chamferRadius: 0.08)
            case .sphere:
                geometry = SCNSphere(radius: 0.85)
            case .capsule:
                geometry = SCNCapsule(capRadius: 0.45, height: 1.7)
            case .cone:
                geometry = SCNCone(topRadius: 0.0, bottomRadius: 0.75, height: 1.6)
            case .cylinder:
                geometry = SCNCylinder(radius: 0.65, height: 1.6)
            case .torus:
                geometry = SCNTorus(ringRadius: 0.82, pipeRadius: 0.24)
            case .plane:
                geometry = SCNPlane(width: 1.8, height: 1.8)
            }

            let material = SCNMaterial()
            applyMaterialSettings(materialSettings, textures: materialTextures, to: material)
            geometry.materials = [material]
            return geometry
        }

        private func geometry(
            for settings: Scene3DTextNodeSettings,
            materialSettings: Scene3DMaterialNodeSettings,
            materialTextures: Scene3DMaterialTextures?
        ) -> SCNGeometry {
            let text = SCNText(string: settings.text, extrusionDepth: settings.extrusionDepth)
            text.chamferRadius = settings.chamferRadius
            text.flatness = CGFloat(settings.flatness)
            if settings.fontName.isEmpty {
                text.font = NSFont.systemFont(ofSize: CGFloat(settings.fontSize), weight: .bold)
            } else {
                text.font = NSFont(name: settings.fontName, size: CGFloat(settings.fontSize)) ?? NSFont.systemFont(ofSize: CGFloat(settings.fontSize), weight: .bold)
            }

            let material = SCNMaterial()
            applyMaterialSettings(materialSettings, textures: materialTextures, to: material)
            text.materials = [material]
            return text
        }

        private func encodeCoreImageEffectPass(
            _ pass: PreviewCoreImagePass,
            with pipelineState: MTLRenderPipelineState,
            sourceTexture: MTLTexture,
            outputTexture: MTLTexture,
            commandBuffer: MTLCommandBuffer,
            drawableSize: CGSize
        ) {
            guard let descriptor = offscreenRenderPassDescriptor(for: outputTexture),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }

            var uniforms = CoreImageEffectUniformsGPU(
                resolution: SIMD2(Float(drawableSize.width), Float(drawableSize.height)),
                primary: pass.primary,
                secondary: pass.secondary,
                effectIndex: UInt32(Self.coreImageEffectIndex(for: pass.effect))
            )

            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentTexture(sourceTexture, index: 0)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CoreImageEffectUniformsGPU>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        private func compileCoreImageEffectPipeline(for view: MTKView, device: MTLDevice) -> MTLRenderPipelineState? {
            do {
                let library = try device.makeLibrary(source: Self.coreImageEffectShaderSource, options: nil)
                guard
                    let vertexFunction = library.makeFunction(name: "coreImageEffectVertex"),
                    let fragmentFunction = library.makeFunction(name: "coreImageEffectFragment")
                else {
                    return nil
                }

                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertexFunction
                descriptor.fragmentFunction = fragmentFunction
                descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                return nil
            }
        }

        private func makeFloatUniformBuffer(from uniforms: [UniformDescriptor]) -> [Float] {
            let values = uniforms.compactMap { uniform -> Float? in
                guard case .float(let value) = uniform.defaultValue else { return nil }
                return Float(value)
            }
            return padded(values, maxCount: MetalPreviewView.maxFloatUniforms, filler: 0)
        }

        private func makeColorUniformBuffer(from uniforms: [UniformDescriptor]) -> [SIMD4<Float>] {
            let values = uniforms.compactMap { uniform -> SIMD4<Float>? in
                guard case .color(let value) = uniform.defaultValue else { return nil }
                return value
            }
            return padded(values, maxCount: MetalPreviewView.maxColorUniforms, filler: SIMD4<Float>(repeating: 0))
        }

        private func makePointUniformBuffer(from uniforms: [UniformDescriptor]) -> [SIMD2<Float>] {
            let values = uniforms.compactMap { uniform -> SIMD2<Float>? in
                guard case .point(let value) = uniform.defaultValue else { return nil }
                return SIMD2(Float(value.x), Float(value.y))
            }
            return padded(values, maxCount: MetalPreviewView.maxPointUniforms, filler: SIMD2<Float>(repeating: 0))
        }

        private func makePoint3UniformBuffer(from uniforms: [UniformDescriptor]) -> [SIMD3<Float>] {
            let values = uniforms.compactMap { uniform -> SIMD3<Float>? in
                guard case .point3(let value) = uniform.defaultValue else { return nil }
                return SIMD3(Float(value.x), Float(value.y), Float(value.z))
            }
            return padded(values, maxCount: MetalPreviewView.maxPoint3Uniforms, filler: SIMD3<Float>(repeating: 0))
        }

        private func makePoint4UniformBuffer(from uniforms: [UniformDescriptor]) -> [SIMD4<Float>] {
            let values = uniforms.compactMap { uniform -> SIMD4<Float>? in
                guard case .point4(let value) = uniform.defaultValue else { return nil }
                return SIMD4(Float(value.x), Float(value.y), Float(value.z), Float(value.w))
            }
            return padded(values, maxCount: MetalPreviewView.maxPoint4Uniforms, filler: SIMD4<Float>(repeating: 0))
        }

        private func makeBoolUniformBuffer(from uniforms: [UniformDescriptor]) -> [UInt32] {
            let values = uniforms.compactMap { uniform -> UInt32? in
                guard case .bool(let value) = uniform.defaultValue else { return nil }
                return value ? 1 : 0
            }
            return padded(values, maxCount: MetalPreviewView.maxBoolUniforms, filler: 0)
        }

        private func padded<T>(_ source: [T], maxCount: Int, filler: T) -> [T] {
            Array(source.prefix(maxCount)) + Array(repeating: filler, count: max(0, maxCount - source.count))
        }

        private func makeDateVector() -> SIMD4<Float> {
            let now = Date()
            let calendar = Calendar(identifier: .gregorian)
            let components = calendar.dateComponents([.year, .month, .day], from: now)
            let seconds = calendar.component(.hour, from: now) * 3600
                + calendar.component(.minute, from: now) * 60
                + calendar.component(.second, from: now)
            return SIMD4(
                Float(components.year ?? 0),
                Float(components.month ?? 0),
                Float(components.day ?? 0),
                Float(seconds)
            )
        }

        private func startRedrawLoop() {
            redrawTimer?.invalidate()
            redrawTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                guard let self, let view = self.view else { return }
                view.draw()
            }
            RunLoop.main.add(redrawTimer!, forMode: .common)
        }

        private func signature(for configuration: PreviewRenderConfiguration) -> String {
            switch configuration {
            case .empty:
                return "empty"
            case .single(let pass):
                let imageSignature = pass.imageUniformSources.enumerated().map { index, source in
                    "\(index):\(source.map(signature(for:)) ?? "nil")"
                }.joined(separator: "|")
                return "single:\(pass.metalSource.hashValue):\(imageSignature)"
            case .trail:
                return "trail"
            case .circle:
                return "circle"
            case .clear:
                return "clear"
            case .image(let pass):
                return "image:\(pass.nodeID.uuidString)"
            case .videoPlayer(let pass):
                return "videoPlayer:\(pass.nodeID.uuidString)"
            case .video:
                return "video"
            case .coreImage(let pass):
                return "coreimage:\(pass.nodeID.uuidString):\(pass.effect.rawValue):\(signature(for: pass.source))"
            case .underwater(let pass):
                return "underwater:\(pass.nodeID.uuidString):\(signature(for: pass.source))"
            case .feedback(let pass):
                return "feedback:\(pass.nodeID.uuidString):\(signature(for: pass.source))"
            case .mix(let primary, let secondary, _):
                return "mix:\(signature(for: primary)):\(signature(for: secondary))"
            case .transform(let pass):
                return "transform:\(pass.nodeID.uuidString):\(signature(for: pass.source))"
            case .lineBatch(let pass):
                return "lineBatch:\(pass.nodeID.uuidString):\(pass.instances.count)"
            case .scene3DPrimitive(let pass):
                return "scene3d:\(pass.nodeID.uuidString):\(pass.settings.primitive.rawValue):\(pass.settings.positionX):\(pass.settings.positionY):\(pass.settings.positionZ):\(pass.settings.rotationX):\(pass.settings.rotationY):\(pass.settings.rotationZ):\(pass.settings.scale):\(pass.settings.cameraDistance):\(pass.settings.cameraOrbit):\(pass.settings.cameraPitch):\(pass.settings.cameraPanX):\(pass.settings.cameraPanY):\(pass.settings.lightIntensity):\(signature(for: pass.materialMaps))"
            case .scene3DText(let pass):
                return "scene3dtext:\(pass.nodeID.uuidString):\(pass.settings.text):\(pass.settings.fontName):\(pass.settings.fontSize):\(pass.settings.extrusionDepth):\(pass.settings.chamferRadius):\(pass.settings.flatness):\(pass.settings.positionX):\(pass.settings.positionY):\(pass.settings.positionZ):\(pass.settings.rotationX):\(pass.settings.rotationY):\(pass.settings.rotationZ):\(pass.settings.scale):\(pass.settings.cameraDistance):\(pass.settings.cameraOrbit):\(pass.settings.cameraPitch):\(pass.settings.cameraPanX):\(pass.settings.cameraPanY):\(pass.settings.lightIntensity):\(signature(for: pass.materialMaps))"
            case .scene3DModel(let pass):
                return "scene3dmodel:\(pass.nodeID.uuidString):\(pass.settings.filename):\(pass.settings.bookmarkData.hashValue):\(signature(for: pass.materialMaps))"
            case .scene3DGaussianSplat(let pass):
                return "gaussiansplat:\(pass.nodeID.uuidString):\(gaussianSplatAssetSignature(for: pass.settings))"
            case .scene3DParticle(let pass):
                return "scene3dparticle:\(pass.nodeID.uuidString):\(pass.spriteSource.map(signature(for:)) ?? "default")"
            case .scene3DRender(let pass):
                return "scene3drender:\(pass.nodeID.uuidString):\(pass.sources.map(signature(for:)).joined(separator: ":"))"
            case .transition(let pass):
                return "transition:\(pass.style.rawValue):\(signature(for: pass.primary)):\(signature(for: pass.secondary))"
            case .layers(let layers, _):
                return "layers:\(layers.map { signature(for: $0.source) }.joined(separator: ":"))"
            }
        }

        private func signature(for source: PreviewPassSource) -> String {
            switch source {
            case .shader(let pass):
                let imageSignature = pass.imageUniformSources.enumerated().map { index, source in
                    "\(index):\(source.map(signature(for:)) ?? "nil")"
                }.joined(separator: "|")
                return "shader:\(pass.metalSource.hashValue):\(imageSignature)"
            case .trail:
                return "trail"
            case .circle:
                return "circle"
            case .clear:
                return "clear"
            case .image(let pass):
                return "image:\(pass.nodeID.uuidString)"
            case .videoPlayer(let pass):
                return "videoPlayer:\(pass.nodeID.uuidString)"
            case .video:
                return "video"
            case .coreImage(let pass):
                return "coreimage:\(pass.nodeID.uuidString):\(pass.effect.rawValue):\(signature(for: pass.source))"
            case .underwater(let pass):
                return "underwater:\(pass.nodeID.uuidString):\(signature(for: pass.source))"
            case .mix(let primary, let secondary, _):
                return "mix:\(signature(for: primary)):\(signature(for: secondary))"
            case .transform(let pass):
                return "transform:\(pass.nodeID.uuidString):\(signature(for: pass.source))"
            case .lineBatch(let pass):
                return "lineBatch:\(pass.nodeID.uuidString):\(pass.instances.count)"
            case .scene3DPrimitive(let pass):
                return "scene3d:\(pass.nodeID.uuidString):\(pass.settings.primitive.rawValue):\(pass.settings.positionX):\(pass.settings.positionY):\(pass.settings.positionZ):\(pass.settings.rotationX):\(pass.settings.rotationY):\(pass.settings.rotationZ):\(pass.settings.scale):\(pass.settings.cameraDistance):\(pass.settings.cameraOrbit):\(pass.settings.cameraPitch):\(pass.settings.cameraPanX):\(pass.settings.cameraPanY):\(pass.settings.lightIntensity):\(signature(for: pass.materialMaps))"
            case .scene3DText(let pass):
                return "scene3dtext:\(pass.nodeID.uuidString):\(pass.settings.text):\(pass.settings.fontName):\(pass.settings.fontSize):\(pass.settings.extrusionDepth):\(pass.settings.chamferRadius):\(pass.settings.flatness):\(pass.settings.positionX):\(pass.settings.positionY):\(pass.settings.positionZ):\(pass.settings.rotationX):\(pass.settings.rotationY):\(pass.settings.rotationZ):\(pass.settings.scale):\(pass.settings.cameraDistance):\(pass.settings.cameraOrbit):\(pass.settings.cameraPitch):\(pass.settings.cameraPanX):\(pass.settings.cameraPanY):\(pass.settings.lightIntensity):\(signature(for: pass.materialMaps))"
            case .scene3DModel(let pass):
                return "scene3dmodel:\(pass.nodeID.uuidString):\(pass.settings.filename):\(pass.settings.bookmarkData.hashValue):\(signature(for: pass.materialMaps))"
            case .scene3DGaussianSplat(let pass):
                return "gaussiansplat:\(pass.nodeID.uuidString):\(gaussianSplatAssetSignature(for: pass.settings))"
            case .scene3DParticle(let pass):
                return "scene3dparticle:\(pass.nodeID.uuidString):\(pass.spriteSource.map(signature(for:)) ?? "default")"
            case .scene3DSource(let source):
                return "scene3dsource:\(signature(for: source))"
            case .scene3DRender(let pass):
                return "scene3drender:\(pass.nodeID.uuidString):\(pass.sources.map(signature(for:)).joined(separator: ":"))"
            case .transition(let pass):
                return "transition:\(pass.style.rawValue):\(signature(for: pass.primary)):\(signature(for: pass.secondary))"
            case .layers(let layers, _):
                return "layers:\(layers.map { signature(for: $0.source) }.joined(separator: ":"))"
            case .feedback(let pass):
                return "feedback:\(pass.nodeID.uuidString):\(signature(for: pass.source))"
            case .feedbackHistory(let nodeID):
                return "feedbackHistory:\(nodeID.uuidString)"
            }
        }

        private func signature(for source: PreviewScene3DSource) -> String {
            switch source {
            case .primitive(let pass):
                return "primitive:\(pass.nodeID.uuidString):\(pass.settings.primitive.rawValue):\(pass.settings.positionX):\(pass.settings.positionY):\(pass.settings.positionZ):\(pass.settings.rotationX):\(pass.settings.rotationY):\(pass.settings.rotationZ):\(pass.settings.scale):\(pass.settings.cameraDistance):\(pass.settings.cameraOrbit):\(pass.settings.cameraPitch):\(pass.settings.cameraPanX):\(pass.settings.cameraPanY):\(pass.settings.lightIntensity):\(signature(for: pass.materialMaps))"
            case .text(let pass):
                return "text:\(pass.nodeID.uuidString):\(pass.settings.text):\(pass.settings.fontName):\(pass.settings.fontSize):\(pass.settings.extrusionDepth):\(pass.settings.chamferRadius):\(pass.settings.flatness):\(pass.settings.positionX):\(pass.settings.positionY):\(pass.settings.positionZ):\(pass.settings.rotationX):\(pass.settings.rotationY):\(pass.settings.rotationZ):\(pass.settings.scale):\(pass.settings.cameraDistance):\(pass.settings.cameraOrbit):\(pass.settings.cameraPitch):\(pass.settings.cameraPanX):\(pass.settings.cameraPanY):\(pass.settings.lightIntensity):\(signature(for: pass.materialMaps))"
            case .model(let pass):
                return "model:\(pass.nodeID.uuidString):\(pass.settings.filename):\(pass.settings.bookmarkData.hashValue):\(signature(for: pass.materialMaps))"
            case .gaussianSplat(let pass):
                return "gaussiansplat:\(pass.nodeID.uuidString):\(gaussianSplatAssetSignature(for: pass.settings))"
            case .particle(let pass):
                return "particle:\(pass.nodeID.uuidString):\(pass.spriteSource.map(signature(for:)) ?? "default")"
            case .light(let pass):
                return "light:\(pass.settings.type.rawValue):\(pass.settings.positionX):\(pass.settings.positionY):\(pass.settings.positionZ):\(pass.settings.rotationX):\(pass.settings.rotationY):\(pass.settings.rotationZ):\(pass.settings.intensity):\(pass.settings.innerSpotAngle):\(pass.settings.outerSpotAngle):\(pass.settings.castsShadow)"
            case .transform(
                let nodeID,
                let child,
                _,
                _,
                _,
                _,
                _,
                _,
                _,
                _,
                _
            ):
                return "transform:\(nodeID.uuidString):\(signature(for: child))"
            }
        }

        private func signature(for maps: PreviewScene3DMaterialMaps?) -> String {
            guard let maps else { return "nomaps" }
            return [
                maps.diffuse.map(signature(for:)) ?? "nil",
                maps.specular.map(signature(for:)) ?? "nil",
                maps.metallic.map(signature(for:)) ?? "nil",
                maps.bump.map(signature(for:)) ?? "nil",
                maps.displacement.map(signature(for:)) ?? "nil"
            ].joined(separator: "|")
        }

        private func updateTrailHistory(pass: PreviewTrailPass, currentTime: Float) {
            trailHistory.removeAll { currentTime - $0.time > pass.duration }

            guard let point = pass.point else { return }

            let shouldAppend: Bool
            if let last = trailHistory.last {
                let dx = Float(point.x - last.position.x)
                let dy = Float(point.y - last.position.y)
                let distanceSquared = dx * dx + dy * dy
                shouldAppend = distanceSquared > 0.00002 || (currentTime - lastTrailAppendTime) > (1.0 / 90.0)
            } else {
                shouldAppend = true
            }

            guard shouldAppend else { return }

            trailHistory.append(TrailHistoryPoint(position: point, time: currentTime))
            lastTrailAppendTime = currentTime

            if trailHistory.count > Self.maxTrailPoints {
                trailHistory.removeFirst(trailHistory.count - Self.maxTrailPoints)
            }
        }

        private func encodeCirclePass(
            _ pass: PreviewCirclePass,
            with pipelineState: MTLRenderPipelineState,
            into descriptor: MTLRenderPassDescriptor,
            commandBuffer: MTLCommandBuffer
        ) {
            guard
                let point = pass.point,
                let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
            else {
                return
            }

            var uniforms = CircleUniformsGPU(
                position: SIMD2(Float(point.x), Float(point.y)),
                radius: max(pass.radius, 0.001),
                softness: max(0.0, min(1.0, pass.softness)),
                color: pass.color
            )

            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CircleUniformsGPU>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        private static let mixShaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct MixVertexOut {
            float4 position [[position]];
            float2 uv;
        };

        struct MixUniforms {
            float amount;
        };

        vertex MixVertexOut mixVertex(uint vertexID [[vertex_id]]) {
            float2 positions[4] = {
                float2(-1.0, -1.0),
                float2(1.0, -1.0),
                float2(-1.0, 1.0),
                float2(1.0, 1.0)
            };

            float2 uvs[4] = {
                float2(0.0, 1.0),
                float2(1.0, 1.0),
                float2(0.0, 0.0),
                float2(1.0, 0.0)
            };

            MixVertexOut out;
            out.position = float4(positions[vertexID], 0.0, 1.0);
            out.uv = uvs[vertexID];
            return out;
        }

        fragment float4 mixFragment(
            MixVertexOut in [[stage_in]],
            texture2d<float> primaryTexture [[texture(0)]],
            texture2d<float> secondaryTexture [[texture(1)]],
            sampler textureSampler [[sampler(0)]],
            constant MixUniforms& uniforms [[buffer(0)]]
        ) {
            float4 colorA = primaryTexture.sample(textureSampler, in.uv);
            float4 colorB = secondaryTexture.sample(textureSampler, in.uv);
            return mix(colorA, colorB, clamp(uniforms.amount, 0.0, 1.0));
        }
        """

        private static let transformShaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct TransformVertexOut {
            float4 position [[position]];
            float2 uv;
        };

        struct TransformUniformsGPU {
            float3 position;
            float2 scale;
            float3 rotationRadians;
            float opacity;
            float4 tint;
        };

        vertex TransformVertexOut transformVertex(
            uint vertexID [[vertex_id]],
            constant TransformUniformsGPU& uniforms [[buffer(0)]]
        ) {
            float2 positions[4] = {
                float2(-1.0, -1.0),
                float2(1.0, -1.0),
                float2(-1.0, 1.0),
                float2(1.0, 1.0)
            };

            float2 uvs[4] = {
                float2(0.0, 1.0),
                float2(1.0, 1.0),
                float2(0.0, 0.0),
                float2(1.0, 0.0)
            };

            TransformVertexOut out;
            float3 local = float3(positions[vertexID] * uniforms.scale, 0.0);

            float cx = cos(uniforms.rotationRadians.x);
            float sx = sin(uniforms.rotationRadians.x);
            float cy = cos(uniforms.rotationRadians.y);
            float sy = sin(uniforms.rotationRadians.y);
            float cz = cos(uniforms.rotationRadians.z);
            float sz = sin(uniforms.rotationRadians.z);

            float3 rotatedX = float3(
                local.x,
                local.y * cx - local.z * sx,
                local.y * sx + local.z * cx
            );
            float3 rotatedXY = float3(
                rotatedX.x * cy + rotatedX.z * sy,
                rotatedX.y,
                -rotatedX.x * sy + rotatedX.z * cy
            );
            float3 rotatedXYZ = float3(
                rotatedXY.x * cz - rotatedXY.y * sz,
                rotatedXY.x * sz + rotatedXY.y * cz,
                rotatedXY.z
            );

            float3 world = rotatedXYZ + float3(
                uniforms.position.x * 2.0 - 1.0,
                1.0 - uniforms.position.y * 2.0,
                uniforms.position.z
            );
            float perspective = 1.0 / max(0.2, 1.0 - world.z * 0.35);
            out.position = float4(world.xy * perspective, 0.0, 1.0);
            out.uv = uvs[vertexID];
            return out;
        }

        fragment float4 transformFragment(
            TransformVertexOut in [[stage_in]],
            texture2d<float> sourceTexture [[texture(0)]],
            sampler textureSampler [[sampler(0)]],
            constant TransformUniformsGPU& uniforms [[buffer(0)]]
        ) {
            float4 color = sourceTexture.sample(textureSampler, in.uv);
            color *= uniforms.tint;
            float opacity = clamp(uniforms.opacity, 0.0, 1.0);
            color.rgb *= opacity;
            color.a *= opacity;
            return color;
        }
        """

        private static let lineShaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct LineInstanceGPU {
            float3 position;
            float2 scale;
            float rotationRadiansZ;
            float4 color;
        };

        struct LineVertexOut {
            float4 position [[position]];
            float4 color;
        };

        vertex LineVertexOut lineVertex(
            uint vertexID [[vertex_id]],
            uint instanceID [[instance_id]],
            constant LineInstanceGPU* instances [[buffer(0)]]
        ) {
            float2 positions[4] = {
                float2(-1.0, -1.0),
                float2(1.0, -1.0),
                float2(-1.0, 1.0),
                float2(1.0, 1.0)
            };

            LineInstanceGPU instance = instances[instanceID];
            float2 local = positions[vertexID] * instance.scale;
            float c = cos(instance.rotationRadiansZ);
            float s = sin(instance.rotationRadiansZ);
            float2 rotated = float2(
                local.x * c - local.y * s,
                local.x * s + local.y * c
            );

            float3 world = float3(
                rotated.x + (instance.position.x * 2.0 - 1.0),
                rotated.y + (1.0 - instance.position.y * 2.0),
                instance.position.z
            );
            float perspective = 1.0 / max(0.2, 1.0 - world.z * 0.35);

            LineVertexOut out;
            out.position = float4(world.xy * perspective, 0.0, 1.0);
            out.color = instance.color;
            return out;
        }

        fragment float4 lineFragment(LineVertexOut in [[stage_in]]) {
            return in.color;
        }
        """

        private static let transitionShaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct TransitionVertexOut {
            float4 position [[position]];
            float2 uv;
        };

        struct TransitionUniformsGPU {
            float progress;
            float softness;
            uint styleIndex;
        };

        vertex TransitionVertexOut transitionVertex(uint vertexID [[vertex_id]]) {
            float2 positions[4] = {
                float2(-1.0, -1.0),
                float2(1.0, -1.0),
                float2(-1.0, 1.0),
                float2(1.0, 1.0)
            };

            float2 uvs[4] = {
                float2(0.0, 1.0),
                float2(1.0, 1.0),
                float2(0.0, 0.0),
                float2(1.0, 0.0)
            };

            TransitionVertexOut out;
            out.position = float4(positions[vertexID], 0.0, 1.0);
            out.uv = uvs[vertexID];
            return out;
        }

        fragment float4 transitionFragment(
            TransitionVertexOut in [[stage_in]],
            texture2d<float> primaryTexture [[texture(0)]],
            texture2d<float> secondaryTexture [[texture(1)]],
            sampler textureSampler [[sampler(0)]],
            constant TransitionUniformsGPU& uniforms [[buffer(0)]]
        ) {
            float4 colorA = primaryTexture.sample(textureSampler, in.uv);
            float4 colorB = secondaryTexture.sample(textureSampler, in.uv);
            float progress = clamp(uniforms.progress, 0.0, 1.0);
            float softness = max(uniforms.softness, 0.0001);
            float mask = 0.0;

            switch (uniforms.styleIndex) {
                case 1: {
                    float radius = length(in.uv - 0.5) * 1.41421356;
                    mask = smoothstep(progress - softness, progress + softness, radius);
                    break;
                }
                case 2: {
                    float2 grid = floor(in.uv * 10.0);
                    float checker = fmod(grid.x + grid.y, 2.0);
                    float threshold = progress + checker * 0.12 - 0.06;
                    float diagonal = (in.uv.x + in.uv.y) * 0.5;
                    mask = smoothstep(threshold - softness, threshold + softness, diagonal);
                    break;
                }
                default:
                    mask = smoothstep(progress - softness, progress + softness, in.uv.x);
                    break;
            }

            return mix(colorA, colorB, clamp(mask, 0.0, 1.0));
        }
        """

        private static let circleShaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct CircleVertexOut {
            float4 position [[position]];
            float2 uv;
        };

        struct CircleUniformsGPU {
            float2 position;
            float radius;
            float softness;
            float4 color;
        };

        vertex CircleVertexOut circleVertex(uint vertexID [[vertex_id]]) {
            float2 positions[4] = {
                float2(-1.0, -1.0),
                float2(1.0, -1.0),
                float2(-1.0, 1.0),
                float2(1.0, 1.0)
            };

            float2 uvs[4] = {
                float2(0.0, 1.0),
                float2(1.0, 1.0),
                float2(0.0, 0.0),
                float2(1.0, 0.0)
            };

            CircleVertexOut out;
            out.position = float4(positions[vertexID], 0.0, 1.0);
            out.uv = uvs[vertexID];
            return out;
        }

        fragment float4 circleFragment(CircleVertexOut in [[stage_in]],
                                       constant CircleUniformsGPU& uniforms [[buffer(0)]]) {
            float distanceToCenter = distance(in.uv, uniforms.position);
            float edge = max(uniforms.radius * max(uniforms.softness, 0.001), 0.0005);
            float alpha = 1.0 - smoothstep(uniforms.radius - edge, uniforms.radius, distanceToCenter);
            return float4(uniforms.color.rgb * uniforms.color.a * alpha, uniforms.color.a * alpha);
        }
        """

        private static let gaussianSplatShaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct GaussianSplatVertexGPU {
            float4 position;
            float4 color;
            float4 scale;
            float4 rotation;
        };

        struct GaussianSplatUniformsGPU {
            float2 resolution;
            float3 position;
            float scale;
            float3 rotationRadians;
            float cameraDistance;
            float cameraOrbitRadians;
            float cameraPitchRadians;
            float2 cameraPan;
            float pointSize;
            float opacity;
            float explode;
            float chaos;
            float particleSpeed;
            float particleGravity;
            float particleTurbulence;
            float particleBoundary;
            float time;
            float isPanorama;
        };

        struct GaussianSplatVertexOut {
            float4 position [[position]];
            float4 color;
            float2 localUV;
        };

        float3 rotateX(float3 p, float angle) {
            float s = sin(angle);
            float c = cos(angle);
            return float3(p.x, p.y * c - p.z * s, p.y * s + p.z * c);
        }

        float3 rotateY(float3 p, float angle) {
            float s = sin(angle);
            float c = cos(angle);
            return float3(p.x * c + p.z * s, p.y, -p.x * s + p.z * c);
        }

        float3 rotateZ(float3 p, float angle) {
            float s = sin(angle);
            float c = cos(angle);
            return float3(p.x * c - p.y * s, p.x * s + p.y * c, p.z);
        }

        float3 quatRotate(float4 q, float3 v) {
            q = normalize(q);
            float3 u = q.yzw;
            float s = q.x;
            return 2.0 * dot(u, v) * u + (s * s - dot(u, u)) * v + 2.0 * s * cross(u, v);
        }

        float hash13(float3 p) {
            p = fract(p * float3(0.1031, 0.11369, 0.13787));
            p += dot(p, p.yzx + 19.19);
            return fract((p.x + p.y) * p.z);
        }

        float3 randomDirection(float3 seed) {
            float x = hash13(seed + 13.1) * 2.0 - 1.0;
            float y = hash13(seed + 47.7) * 2.0 - 1.0;
            float z = hash13(seed + 91.3) * 2.0 - 1.0;
            return normalize(float3(x, y, z) + 0.0001);
        }

        float bounceAxis(float value, float limit) {
            float span = max(limit * 2.0, 0.0001);
            float wrapped = fmod(value + limit, span * 2.0);
            if (wrapped < 0.0) {
                wrapped += span * 2.0;
            }
            float mirrored = wrapped <= span ? wrapped : span * 2.0 - wrapped;
            return mirrored - limit;
        }

        float3 bounceBox(float3 value, float3 halfExtents) {
            return float3(
                bounceAxis(value.x, halfExtents.x),
                bounceAxis(value.y, halfExtents.y),
                bounceAxis(value.z, halfExtents.z)
            );
        }

        float3 applySceneRotation(float3 p, constant GaussianSplatUniformsGPU& uniforms) {
            p = rotateX(p, uniforms.rotationRadians.x);
            p = rotateY(p, uniforms.rotationRadians.y);
            p = rotateZ(p, uniforms.rotationRadians.z);
            p = rotateY(p, uniforms.cameraOrbitRadians);
            p = rotateX(p, uniforms.cameraPitchRadians);
            return p;
        }

        float2 projectClip(float3 p, constant GaussianSplatUniformsGPU& uniforms) {
            float viewZ = p.z + uniforms.cameraDistance;
            float nearPlane = mix(0.05, 1.25, uniforms.isPanorama);
            float aspect = uniforms.resolution.x / max(uniforms.resolution.y, 1.0);
            return float2((p.x / max(viewZ, nearPlane)) / aspect, p.y / max(viewZ, nearPlane));
        }

        vertex GaussianSplatVertexOut gaussianSplatVertex(
            uint vertexID [[vertex_id]],
            uint instanceID [[instance_id]],
            constant GaussianSplatVertexGPU* vertices [[buffer(0)]],
            constant GaussianSplatUniformsGPU& uniforms [[buffer(1)]]
        ) {
            GaussianSplatVertexGPU splat = vertices[instanceID];
            float3 p = splat.position.xyz * uniforms.scale;
            float3 localP = p;
            float3 radialDirection = normalize(localP + 0.0001);
            float3 chaosDirection = randomDirection(splat.position.xyz);
            float seed = hash13(splat.position.xyz);
            float3 travelDirection = normalize(mix(radialDirection, chaosDirection, uniforms.chaos));
            if (uniforms.explode > 0.0001) {
                float speed = max(uniforms.particleSpeed, 0.0001);
                float particleTime = uniforms.time * speed * 0.35 + seed * 9.0;
                float strength = clamp(uniforms.explode / 100.0, 0.0, 1.0);
                float3 tangent = normalize(cross(travelDirection, float3(0.0, 1.0, 0.0)) + randomDirection(splat.position.zyx) * 0.25 + 0.0001);
                float swirl = sin(uniforms.time * (1.7 + seed * 2.0) + seed * 18.8496);
                float bob = cos(uniforms.time * (1.2 + seed) + seed * 12.5664);
                float3 turbulence = (tangent * swirl + randomDirection(splat.position.yxz) * bob) * uniforms.particleTurbulence * uniforms.chaos;
                float3 velocity = (travelDirection * uniforms.particleBoundary * 0.45 + turbulence) * strength;
                float3 moved = p + velocity * particleTime;
                moved.y -= uniforms.particleGravity * particleTime * particleTime * 0.18 * strength;

                float boxScale = mix(1.08, 1.35, strength);
                float3 halfExtents = float3(uniforms.particleBoundary * boxScale);
                p = bounceBox(moved, halfExtents);
            }
            p += uniforms.position;
            p = applySceneRotation(p, uniforms);
            p.xy += uniforms.cameraPan;

            float3 axisX = quatRotate(splat.rotation, float3(splat.scale.x, 0.0, 0.0)) * uniforms.scale * uniforms.pointSize;
            float3 axisY = quatRotate(splat.rotation, float3(0.0, splat.scale.y, 0.0)) * uniforms.scale * uniforms.pointSize;
            float3 axisZ = quatRotate(splat.rotation, float3(0.0, 0.0, splat.scale.z)) * uniforms.scale * uniforms.pointSize;
            axisX = applySceneRotation(axisX, uniforms);
            axisY = applySceneRotation(axisY, uniforms);
            axisZ = applySceneRotation(axisZ, uniforms);

            float viewZ = p.z + uniforms.cameraDistance;
            float nearPlane = mix(0.05, 1.25, uniforms.isPanorama);
            if (viewZ <= nearPlane) {
                GaussianSplatVertexOut out;
                out.position = float4(3.0, 3.0, 1.0, 1.0);
                out.color = float4(0.0);
                out.localUV = float2(2.0);
                return out;
            }
            float2 centerClip = projectClip(p, uniforms);
            float2 projectedX = projectClip(p + axisX, uniforms) - centerClip;
            float2 projectedY = projectClip(p + axisY, uniforms) - centerClip;
            float2 projectedZ = projectClip(p + axisZ, uniforms) - centerClip;
            float lx = dot(projectedX, projectedX);
            float ly = dot(projectedY, projectedY);
            float lz = dot(projectedZ, projectedZ);
            float2 axisA = projectedX;
            float2 axisB = projectedY;
            if (ly > lx && ly >= lz) {
                axisA = projectedY;
                axisB = (lx > lz) ? projectedX : projectedZ;
            } else if (lz > lx && lz > ly) {
                axisA = projectedZ;
                axisB = (lx > ly) ? projectedX : projectedY;
            } else {
                axisB = (ly > lz) ? projectedY : projectedZ;
            }

            float minPixels = mix(1.5, 4.0, uniforms.isPanorama);
            float2 minAxis = float2(minPixels / max(uniforms.resolution.x, 1.0), minPixels / max(uniforms.resolution.y, 1.0));
            if (length(axisA) < length(minAxis)) {
                axisA = float2(minAxis.x, 0.0);
            }
            if (length(axisB) < length(minAxis)) {
                axisB = float2(0.0, minAxis.y);
            }

            float2 corners[4] = {
                float2(-1.0, -1.0),
                float2( 1.0, -1.0),
                float2(-1.0,  1.0),
                float2( 1.0,  1.0)
            };
            float2 local = corners[vertexID];

            GaussianSplatVertexOut out;
            out.position = float4(centerClip + local.x * axisA * 2.5 + local.y * axisB * 2.5, clamp(viewZ / 200.0, 0.0, 1.0), 1.0);
            out.color = float4(splat.color.rgb, splat.color.a * uniforms.opacity);
            out.localUV = local;
            return out;
        }

        fragment float4 gaussianSplatFragment(
            GaussianSplatVertexOut in [[stage_in]]
        ) {
            float d = dot(in.localUV, in.localUV);
            if (d > 1.0) {
                discard_fragment();
            }
            float alpha = exp(-d * 2.8) * in.color.a;
            return float4(in.color.rgb, alpha);
        }
        """

        private static let layerShaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct LayerVertexOut {
            float4 position [[position]];
            float2 uv;
        };

        struct LayerUniforms {
            float opacity;
        };

        vertex LayerVertexOut layerVertex(uint vertexID [[vertex_id]]) {
            float2 positions[4] = {
                float2(-1.0, -1.0),
                float2(1.0, -1.0),
                float2(-1.0, 1.0),
                float2(1.0, 1.0)
            };

            float2 uvs[4] = {
                float2(0.0, 1.0),
                float2(1.0, 1.0),
                float2(0.0, 0.0),
                float2(1.0, 0.0)
            };

            LayerVertexOut out;
            out.position = float4(positions[vertexID], 0.0, 1.0);
            out.uv = uvs[vertexID];
            return out;
        }

        fragment float4 layerFragment(
            LayerVertexOut in [[stage_in]],
            texture2d<float> backgroundTexture [[texture(0)]],
            texture2d<float> foregroundTexture [[texture(1)]],
            sampler textureSampler [[sampler(0)]],
            constant LayerUniforms& uniforms [[buffer(0)]]
        ) {
            float4 background = backgroundTexture.sample(textureSampler, in.uv);
            float4 foreground = foregroundTexture.sample(textureSampler, in.uv);
            float opacity = clamp(uniforms.opacity, 0.0, 1.0);
            foreground.rgb *= opacity;
            foreground.a *= opacity;
            return foreground + background * (1.0 - foreground.a);
        }
        """

        private static let feedbackShaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct FeedbackVertexOut {
            float4 position [[position]];
            float2 uv;
        };

        struct FeedbackUniforms {
            float level;
            uint blendMode;
        };

        vertex FeedbackVertexOut feedbackVertex(uint vertexID [[vertex_id]]) {
            float2 positions[4] = {
                float2(-1.0, -1.0),
                float2(1.0, -1.0),
                float2(-1.0, 1.0),
                float2(1.0, 1.0)
            };

            float2 uvs[4] = {
                float2(0.0, 1.0),
                float2(1.0, 1.0),
                float2(0.0, 0.0),
                float2(1.0, 0.0)
            };

            FeedbackVertexOut out;
            out.position = float4(positions[vertexID], 0.0, 1.0);
            out.uv = uvs[vertexID];
            return out;
        }

        fragment float4 feedbackFragment(
            FeedbackVertexOut in [[stage_in]],
            texture2d<float> currentTexture [[texture(0)]],
            texture2d<float> historyTexture [[texture(1)]],
            sampler textureSampler [[sampler(0)]],
            constant FeedbackUniforms& uniforms [[buffer(0)]]
        ) {
            float4 current = currentTexture.sample(textureSampler, in.uv);
            float4 history = historyTexture.sample(textureSampler, in.uv);
            bool currentIsFallback = current.r > 0.85 && current.g < 0.2 && current.b > 0.85;
            bool historyIsFallback = history.r > 0.85 && history.g < 0.2 && history.b > 0.85;
            if (historyIsFallback) {
                history = float4(0.0);
            }
            if (currentIsFallback) {
                current = history;
            }
            float level = clamp(uniforms.level, 0.0, 0.999);
            float3 feedback = history.rgb * level;
            float3 result = current.rgb;

            switch (uniforms.blendMode) {
                case 1:
                    result = 1.0 - (1.0 - current.rgb) * (1.0 - feedback);
                    break;
                case 2:
                    result = current.rgb * max(feedback, float3(0.0001));
                    break;
                default:
                    result = current.rgb + feedback;
                    break;
            }

            float alpha = clamp(max(current.a, history.a * level), 0.0, 1.0);
            return float4(clamp(result, 0.0, 1.0), alpha);
        }
        """

        private static func blendModeIndex(for blendMode: FeedbackBlendMode) -> Int {
            switch blendMode {
            case .additive:
                return 0
            case .screen:
                return 1
            case .multiply:
                return 2
            }
        }

        private static func transitionStyleIndex(for style: TransitionStyle) -> Int {
            switch style {
            case .wipe:
                return 0
            case .radial:
                return 1
            case .checker:
                return 2
            }
        }

        private static func coreImageEffectIndex(for effect: CoreImageEffectKind) -> Int {
            switch effect {
            case .blur:
                return 0
            case .bloom:
                return 1
            case .hueRotate:
                return 2
            case .posterize:
                return 3
            case .glow:
                return 4
            case .edges:
                return 5
            case .pixellate:
                return 6
            case .twirl:
                return 7
            case .kaleidoscope:
                return 8
            }
        }

        private static let videoShaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VideoVertexOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex VideoVertexOut videoVertex(uint vertexID [[vertex_id]]) {
            float2 positions[4] = {
                float2(-1.0, -1.0),
                float2(1.0, -1.0),
                float2(-1.0, 1.0),
                float2(1.0, 1.0)
            };

            float2 uvs[4] = {
                float2(0.0, 1.0),
                float2(1.0, 1.0),
                float2(0.0, 0.0),
                float2(1.0, 0.0)
            };

            VideoVertexOut out;
            out.position = float4(positions[vertexID], 0.0, 1.0);
            out.uv = uvs[vertexID];
            return out;
        }

        fragment float4 videoFragment(
            VideoVertexOut in [[stage_in]],
            texture2d<float> videoTexture [[texture(0)]],
            sampler textureSampler [[sampler(0)]]
        ) {
            return videoTexture.sample(textureSampler, in.uv);
        }
        """

        private static let coreImageEffectShaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct CoreImageEffectVertexOut {
            float4 position [[position]];
            float2 uv;
        };

        struct CoreImageEffectUniforms {
            float2 resolution;
            float primary;
            float secondary;
            uint effectIndex;
        };

        vertex CoreImageEffectVertexOut coreImageEffectVertex(uint vertexID [[vertex_id]]) {
            float2 positions[4] = {
                float2(-1.0, -1.0),
                float2(1.0, -1.0),
                float2(-1.0, 1.0),
                float2(1.0, 1.0)
            };

            float2 uvs[4] = {
                float2(0.0, 1.0),
                float2(1.0, 1.0),
                float2(0.0, 0.0),
                float2(1.0, 0.0)
            };

            CoreImageEffectVertexOut out;
            out.position = float4(positions[vertexID], 0.0, 1.0);
            out.uv = uvs[vertexID];
            return out;
        }

        float3 rgb2hsv(float3 c) {
            float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
            float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
            float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
            float d = q.x - min(q.w, q.y);
            float e = 1.0e-10;
            return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
        }

        float3 hsv2rgb(float3 c) {
            float3 rgb = clamp(abs(fract(c.x + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
            rgb = rgb * rgb * (3.0 - 2.0 * rgb);
            return c.z * mix(float3(1.0), rgb, c.y);
        }

        float4 sampleBlur(texture2d<float> sourceTexture, sampler textureSampler, float2 uv, float2 texel, float radius) {
            float r = max(radius, 0.0);
            float2 offset1 = texel * r * 1.3846153846;
            float2 offset2 = texel * r * 3.2307692308;

            float4 color = sourceTexture.sample(textureSampler, uv) * 0.2270270270;
            color += sourceTexture.sample(textureSampler, uv + float2(offset1.x, 0.0)) * 0.3162162162;
            color += sourceTexture.sample(textureSampler, uv - float2(offset1.x, 0.0)) * 0.3162162162;
            color += sourceTexture.sample(textureSampler, uv + float2(offset2.x, 0.0)) * 0.0702702703;
            color += sourceTexture.sample(textureSampler, uv - float2(offset2.x, 0.0)) * 0.0702702703;
            color += sourceTexture.sample(textureSampler, uv + float2(0.0, offset1.y)) * 0.3162162162;
            color += sourceTexture.sample(textureSampler, uv - float2(0.0, offset1.y)) * 0.3162162162;
            color += sourceTexture.sample(textureSampler, uv + float2(0.0, offset2.y)) * 0.0702702703;
            color += sourceTexture.sample(textureSampler, uv - float2(0.0, offset2.y)) * 0.0702702703;
            return color;
        }

        float luminance(float3 color) {
            return dot(color, float3(0.299, 0.587, 0.114));
        }

        fragment float4 coreImageEffectFragment(
            CoreImageEffectVertexOut in [[stage_in]],
            texture2d<float> sourceTexture [[texture(0)]],
            sampler textureSampler [[sampler(0)]],
            constant CoreImageEffectUniforms& uniforms [[buffer(0)]]
        ) {
            float2 texel = 1.0 / max(uniforms.resolution, float2(1.0, 1.0));
            float4 source = sourceTexture.sample(textureSampler, in.uv);

            switch (uniforms.effectIndex) {
                case 0: {
                    return sampleBlur(sourceTexture, textureSampler, in.uv, texel, uniforms.primary);
                }
                case 1: {
                    float4 blur = sampleBlur(sourceTexture, textureSampler, in.uv, texel, uniforms.primary);
                    float intensity = max(uniforms.secondary, 0.0);
                    return float4(clamp(source.rgb + blur.rgb * intensity, 0.0, 1.0), source.a);
                }
                case 2: {
                    float3 hsv = rgb2hsv(source.rgb);
                    hsv.x = fract(hsv.x + uniforms.primary);
                    return float4(hsv2rgb(hsv), source.a);
                }
                case 3: {
                    float levels = clamp(uniforms.primary, 2.0, 12.0);
                    float steps = max(levels - 1.0, 1.0);
                    float3 posterized = floor(source.rgb * steps + 0.5) / steps;
                    return float4(posterized, source.a);
                }
                case 4: {
                    float4 blur = sampleBlur(sourceTexture, textureSampler, in.uv, texel, uniforms.primary);
                    float intensity = max(uniforms.secondary, 0.0);
                    float3 glow = max(blur.rgb - source.rgb, 0.0) * intensity;
                    return float4(clamp(source.rgb + glow, 0.0, 1.0), source.a);
                }
                case 5: {
                    float strength = max(uniforms.primary, 0.0);
                    float tl = luminance(sourceTexture.sample(textureSampler, in.uv + texel * float2(-1.0, -1.0)).rgb);
                    float tc = luminance(sourceTexture.sample(textureSampler, in.uv + texel * float2(0.0, -1.0)).rgb);
                    float tr = luminance(sourceTexture.sample(textureSampler, in.uv + texel * float2(1.0, -1.0)).rgb);
                    float ml = luminance(sourceTexture.sample(textureSampler, in.uv + texel * float2(-1.0, 0.0)).rgb);
                    float mr = luminance(sourceTexture.sample(textureSampler, in.uv + texel * float2(1.0, 0.0)).rgb);
                    float bl = luminance(sourceTexture.sample(textureSampler, in.uv + texel * float2(-1.0, 1.0)).rgb);
                    float bc = luminance(sourceTexture.sample(textureSampler, in.uv + texel * float2(0.0, 1.0)).rgb);
                    float br = luminance(sourceTexture.sample(textureSampler, in.uv + texel * float2(1.0, 1.0)).rgb);
                    float gx = -tl - 2.0 * ml - bl + tr + 2.0 * mr + br;
                    float gy = -tl - 2.0 * tc - tr + bl + 2.0 * bc + br;
                    float edge = clamp(length(float2(gx, gy)) * strength, 0.0, 1.0);
                    return float4(float3(edge), source.a);
                }
                case 6: {
                    float2 pixelSize = max(float2(uniforms.primary) / max(uniforms.resolution, float2(1.0)), float2(0.0005));
                    float2 uv = floor(in.uv / pixelSize) * pixelSize + (pixelSize * 0.5);
                    return sourceTexture.sample(textureSampler, clamp(uv, 0.0, 1.0));
                }
                case 7: {
                    float radius = clamp(uniforms.primary, 0.0, 1.0);
                    float angle = uniforms.secondary * 6.2831853;
                    float2 centered = in.uv - 0.5;
                    float dist = length(centered);
                    if (dist < radius && radius > 0.0001) {
                        float percent = (radius - dist) / radius;
                        float theta = percent * percent * angle;
                        float s = sin(theta);
                        float c = cos(theta);
                        centered = float2(c * centered.x - s * centered.y, s * centered.x + c * centered.y);
                    }
                    return sourceTexture.sample(textureSampler, clamp(centered + 0.5, 0.0, 1.0));
                }
                case 8: {
                    float segments = clamp(uniforms.primary, 2.0, 24.0);
                    float spin = uniforms.secondary * 6.2831853;
                    float2 centered = in.uv - 0.5;
                    float angle = atan2(centered.y, centered.x) + spin;
                    float radius = length(centered);
                    float sector = 6.2831853 / segments;
                    angle = fmod(angle, sector);
                    angle = min(angle, sector - angle);
                    float2 warped = float2(cos(angle), sin(angle)) * radius + 0.5;
                    return sourceTexture.sample(textureSampler, clamp(warped, 0.0, 1.0));
                }
                default:
                    return source;
            }
        }
        """

        private static let underwaterShaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct UnderwaterVertexOut {
            float4 position [[position]];
            float2 uv;
        };

        struct UnderwaterUniforms {
            float2 renderSize;
            float time;
            float scale;
            float distortion;
            uint octaves;
            float lacunarity;
            float gain;
            float amplitude;
            float textureScale;
            float uvClampMargin;
        };

        vertex UnderwaterVertexOut underwaterVertex(uint vertexID [[vertex_id]]) {
            float2 positions[4] = {
                float2(-1.0, -1.0),
                float2(1.0, -1.0),
                float2(-1.0, 1.0),
                float2(1.0, 1.0)
            };

            float2 uvs[4] = {
                float2(0.0, 1.0),
                float2(1.0, 1.0),
                float2(0.0, 0.0),
                float2(1.0, 0.0)
            };

            UnderwaterVertexOut out;
            out.position = float4(positions[vertexID], 0.0, 1.0);
            out.uv = uvs[vertexID];
            return out;
        }

        static inline float random(float2 st) {
            return fract(sin(dot(st, float2(12.9898, 78.233))) * 43758.5453123);
        }

        static inline float noise(float2 st) {
            float2 i = floor(st);
            float2 f = fract(st);

            float a = random(i);
            float b = random(i + float2(1.0, 0.0));
            float c = random(i + float2(0.0, 1.0));
            float d = random(i + float2(1.0, 1.0));

            float2 u = f * f * (3.0 - 2.0 * f);

            return mix(a, b, u.x) +
                   (c - a) * u.y * (1.0 - u.x) +
                   (d - b) * u.x * u.y;
        }

        static inline float fbm(float2 st, constant UnderwaterUniforms& uni) {
            float v = 0.0;
            float a = uni.amplitude;
            float2 shift = float2(100.0, 100.0);
            float c = cos(0.5);
            float s = sin(0.5);
            float2x2 rot = float2x2(c, s, -s, c);
            for (uint i = 0; i < uni.octaves; ++i) {
                v += a * noise(st);
                st = (rot * st) * uni.lacunarity + shift;
                a *= uni.gain;
            }
            return v;
        }

        fragment float4 underwaterFragment(
            UnderwaterVertexOut in [[stage_in]],
            constant UnderwaterUniforms& uni [[buffer(0)]],
            texture2d<float> inputImage [[texture(0)]],
            sampler samp [[sampler(0)]]
        ) {
            float2 st = in.uv * uni.scale;

            float2 q = float2(0.0);
            q.x = fbm(st + 0.00 * uni.time, uni);
            q.y = fbm(st + float2(1.0, 0.0), uni);

            float2 r = float2(0.0);
            r.x = fbm(st + q + float2(0.170, 0.060) + 0.318 * uni.time, uni);
            r.y = fbm(st + q + float2(8.3, 2.8) + 0.126 * uni.time, uni);

            float f = fbm(st + r, uni);
            float2 uv = in.uv + float2(f, f) * uni.distortion;
            uv = (uv - 0.5) / max(uni.textureScale, 1e-5) + 0.5;

            float m = clamp(uni.uvClampMargin, 0.0, 0.49);
            uv = clamp(uv, float2(m), float2(1.0 - m));

            return inputImage.sample(samp, uv);
        }
        """

        private static let maxTrailPoints = 256

        private static let trailShaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct TrailVertexOut {
            float4 position [[position]];
            float2 uv;
        };

        struct TrailPoint {
            float2 pos;
            float t;
        };

        struct TrailUniforms {
            float time;
            float radius;
            float trailDuration;
            uint pointCount;
        };

        float3 rainbow(float t) {
            const float tau = 6.28318530718;
            float3 phase = float3(0.0, 0.33, 0.67);
            return 0.5 + 0.5 * cos(tau * (t + phase));
        }

        vertex TrailVertexOut trailVertex(uint vertexID [[vertex_id]]) {
            float2 positions[4] = {
                float2(-1.0, -1.0),
                float2(1.0, -1.0),
                float2(-1.0, 1.0),
                float2(1.0, 1.0)
            };

            float2 uvs[4] = {
                float2(0.0, 1.0),
                float2(1.0, 1.0),
                float2(0.0, 0.0),
                float2(1.0, 0.0)
            };

            TrailVertexOut out;
            out.position = float4(positions[vertexID], 0.0, 1.0);
            out.uv = uvs[vertexID];
            return out;
        }

        fragment float4 trailFragment(
            TrailVertexOut in [[stage_in]],
            constant TrailUniforms& uniforms [[buffer(0)]],
            constant TrailPoint* points [[buffer(1)]]
        ) {
            float2 uv = in.uv;
            float3 accumColor = float3(0.0);
            float accumAlpha = 0.0;

            for (uint i = 0; i < uniforms.pointCount; ++i) {
                TrailPoint p = points[i];
                float age = uniforms.time - p.t;
                if (age < 0.0 || age > uniforms.trailDuration) { continue; }

                float ageNorm = clamp(age / uniforms.trailDuration, 0.0, 1.0);
                float d = distance(uv, p.pos);
                float spatial = exp(-(d * d) / (uniforms.radius * uniforms.radius + 1e-6));
                float temporal = exp(-3.0 * ageNorm);
                float a = spatial * temporal;
                float3 col = rainbow(1.0 - ageNorm);

                accumColor += col * a;
                accumAlpha = 1.0 - (1.0 - accumAlpha) * (1.0 - a);
            }

            accumColor = min(accumColor, float3(1.0));
            return float4(accumColor, accumAlpha);
        }
        """
    }
}

private struct TrailHistoryPoint {
    let position: CGPoint
    let time: Float
}

private final class TrackingMTKView: MTKView {
    var onMouseChange: ((CGPoint?) -> Void)?
    var onMouseButtonChange: ((Bool, Bool) -> Void)?
    var onModifierFlagsChange: ((NSEvent.ModifierFlags) -> Void)?
    var onScrollChange: ((CGPoint) -> Void)?
    private var trackingAreaReference: NSTrackingArea?
    private var localEventMonitors: [Any] = []
    private var leftMouseDown = false
    private var rightMouseDown = false

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        installEventMonitorsIfNeeded()
    }

    deinit {
        localEventMonitors.forEach { NSEvent.removeMonitor($0) }
    }

    override func mouseMoved(with event: NSEvent) {
        publishMousePosition(event)
    }

    override func mouseDragged(with event: NSEvent) {
        publishMousePosition(event)
    }

    override func mouseEntered(with event: NSEvent) {
        publishMousePosition(event)
    }

    override func mouseExited(with event: NSEvent) {
        onMouseChange?(nil)
        leftMouseDown = false
        rightMouseDown = false
        onMouseButtonChange?(false, false)
    }

    override func mouseDown(with event: NSEvent) {
        leftMouseDown = true
        onModifierFlagsChange?(event.modifierFlags)
        publishMousePosition(event)
        onMouseButtonChange?(leftMouseDown, rightMouseDown)
    }

    override func mouseUp(with event: NSEvent) {
        leftMouseDown = false
        onModifierFlagsChange?(event.modifierFlags)
        publishMousePosition(event)
        onMouseButtonChange?(leftMouseDown, rightMouseDown)
    }

    override func rightMouseDown(with event: NSEvent) {
        rightMouseDown = true
        onModifierFlagsChange?(event.modifierFlags)
        publishMousePosition(event)
        onMouseButtonChange?(leftMouseDown, rightMouseDown)
    }

    override func rightMouseUp(with event: NSEvent) {
        rightMouseDown = false
        onModifierFlagsChange?(event.modifierFlags)
        publishMousePosition(event)
        onMouseButtonChange?(leftMouseDown, rightMouseDown)
    }

    override func scrollWheel(with event: NSEvent) {
        onModifierFlagsChange?(event.modifierFlags)
        window?.makeFirstResponder(self)
        let divisor = event.hasPreciseScrollingDeltas ? 40.0 : 10.0
        let delta = CGPoint(
            x: event.scrollingDeltaX / divisor,
            y: event.scrollingDeltaY / divisor
        )
        guard abs(delta.x) > 0.0001 || abs(delta.y) > 0.0001 else { return }
        onScrollChange?(delta)
    }

    private func publishMousePosition(_ event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let normalized = CGPoint(
            x: min(max(location.x / bounds.width, 0.0), 1.0),
            y: min(max(1.0 - (location.y / bounds.height), 0.0), 1.0)
        )
        onMouseChange?(normalized)
    }

    private func installEventMonitorsIfNeeded() {
        guard localEventMonitors.isEmpty else { return }

        let dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .rightMouseDragged]) { [weak self] event in
            guard let self else { return event }
            if self.window === event.window {
                self.onModifierFlagsChange?(event.modifierFlags)
                self.publishMousePosition(event)
            }
            return event
        }

        if let dragMonitor {
            localEventMonitors.append(dragMonitor)
        }
    }
}

private struct PreviewUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var date: SIMD4<Float>
}

private struct MixUniforms {
    var amount: Float
}

private struct TransformUniformsGPU {
    var position: SIMD3<Float>
    var scale: SIMD2<Float>
    var rotationRadians: SIMD3<Float>
    var opacity: Float
    var tint: SIMD4<Float>
}

private struct LineInstanceGPU {
    var position: SIMD3<Float>
    var scale: SIMD2<Float>
    var rotationRadiansZ: Float
    var color: SIMD4<Float>
}

private struct TransitionUniformsGPU {
    var progress: Float
    var softness: Float
    var styleIndex: UInt32
}

private struct TrailPointGPU {
    var pos: SIMD2<Float>
    var t: Float
}

private struct TrailUniformsGPU {
    var time: Float
    var radius: Float
    var trailDuration: Float
    var pointCount: UInt32
}

private struct CircleUniformsGPU {
    var position: SIMD2<Float>
    var radius: Float
    var softness: Float
    var color: SIMD4<Float>
}

private struct FeedbackUniformsGPU {
    var level: Float
    var blendMode: UInt32
}

private struct UnderwaterUniformsGPU {
    var renderSize: SIMD2<Float>
    var time: Float
    var scale: Float
    var distortion: Float
    var octaves: UInt32
    var lacunarity: Float
    var gain: Float
    var amplitude: Float
    var textureScale: Float
    var uvClampMargin: Float
}

private struct CoreImageEffectUniformsGPU {
    var resolution: SIMD2<Float>
    var primary: Float
    var secondary: Float
    var effectIndex: UInt32
}
