//
//  MetalPreviewView.swift
//  MetalNode
//
//  Created by Codex on 3/11/26.
//

import Metal
import MetalKit
import QuartzCore
import SwiftUI
import simd

struct MetalPreviewView: NSViewRepresentable {
    let configuration: PreviewRenderConfiguration
    var onMouseChange: ((CGPoint?) -> Void)? = nil
    var onMouseButtonChange: ((Bool, Bool) -> Void)? = nil
    var onScrollChange: ((CGPoint) -> Void)? = nil

    private static let maxFloatUniforms = 32
    private static let maxColorUniforms = 16
    private static let maxPointUniforms = 16
    private static let maxPoint3Uniforms = 16
    private static let maxPoint4Uniforms = 16
    private static let maxBoolUniforms = 16

    func makeCoordinator() -> Coordinator {
        Coordinator(configuration: configuration)
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
        view.onScrollChange = onScrollChange
        context.coordinator.configure(view: view)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        if let trackingView = nsView as? TrackingMTKView {
            trackingView.onMouseChange = onMouseChange
            trackingView.onMouseButtonChange = onMouseButtonChange
            trackingView.onScrollChange = onScrollChange
        }
        context.coordinator.update(configuration: configuration, view: nsView)
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        private let device: MTLDevice?
        private let commandQueue: MTLCommandQueue?
        private let samplerState: MTLSamplerState?
        private weak var view: MTKView?
        private var redrawTimer: Timer?
        private var startTime = CACurrentMediaTime()

        private var liveConfiguration: PreviewRenderConfiguration
        private var compiledSignature = ""
        private var primaryPipelineState: MTLRenderPipelineState?
        private var secondaryPipelineState: MTLRenderPipelineState?
        private var compositePipelineState: MTLRenderPipelineState?
        private var transformPipelineState: MTLRenderPipelineState?
        private var transitionPipelineState: MTLRenderPipelineState?
        private var layerCompositePipelineState: MTLRenderPipelineState?
        private var feedbackPipelineState: MTLRenderPipelineState?
        private var trailPipelineState: MTLRenderPipelineState?
        private var circlePipelineState: MTLRenderPipelineState?
        private var videoPipelineState: MTLRenderPipelineState?
        private var underwaterPipelineState: MTLRenderPipelineState?
        private var coreImageEffectPipelineState: MTLRenderPipelineState?
        private var trailHistory: [TrailHistoryPoint] = []
        private var lastTrailAppendTime: Float = 0
        private var feedbackHistoryTextures: [UUID: MTLTexture] = [:]
        private var imageTextures: [UUID: (fingerprint: Int, texture: MTLTexture)] = [:]

        init(configuration: PreviewRenderConfiguration) {
            device = MTLCreateSystemDefaultDevice()
            commandQueue = device?.makeCommandQueue()
            liveConfiguration = configuration
            if let device {
                let descriptor = MTLSamplerDescriptor()
                descriptor.minFilter = .linear
                descriptor.magFilter = .linear
                descriptor.sAddressMode = .clampToEdge
                descriptor.tAddressMode = .clampToEdge
                samplerState = device.makeSamplerState(descriptor: descriptor)
            } else {
                samplerState = nil
            }
        }

        func configure(view: MTKView) {
            self.view = view
            compilePipelines(for: view, configuration: liveConfiguration)
            startRedrawLoop()
        }

        func update(configuration: PreviewRenderConfiguration, view: MTKView) {
            self.view = view
            liveConfiguration = configuration
            let newSignature = signature(for: configuration)
            if newSignature != compiledSignature {
                compilePipelines(for: view, configuration: configuration)
            }
            view.draw()
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
                    currentTime: Float(CACurrentMediaTime() - startTime),
                    role: .primary
                )

                renderPassSource(
                    secondary,
                    into: secondaryTexture,
                    commandBuffer: commandBuffer,
                    drawableSize: view.drawableSize,
                    currentTime: Float(CACurrentMediaTime() - startTime),
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
                    currentTime: Float(CACurrentMediaTime() - startTime)
                )
            case .transition(let pass):
                encodeTransitionPass(
                    pass,
                    into: renderPassDescriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: view.drawableSize,
                    currentTime: Float(CACurrentMediaTime() - startTime)
                )
            case .trail(let pass):
                guard let trailPipelineState else { return }
                encodeTrailPass(
                    pass,
                    with: trailPipelineState,
                    into: renderPassDescriptor,
                    commandBuffer: commandBuffer,
                    currentTime: Float(CACurrentMediaTime() - startTime)
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
                encodeImagePass(
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
                    currentTime: Float(CACurrentMediaTime() - startTime)
                )
            case .underwater(let pass):
                encodeUnderwaterPass(
                    pass,
                    into: renderPassDescriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: view.drawableSize,
                    currentTime: Float(CACurrentMediaTime() - startTime)
                )
            case .feedback(let pass):
                encodeFeedbackPass(
                    pass,
                    into: renderPassDescriptor,
                    commandBuffer: commandBuffer,
                    drawableSize: view.drawableSize,
                    currentTime: Float(CACurrentMediaTime() - startTime)
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
                    renderPassSource(
                        layer.source,
                        into: overlayTexture,
                        commandBuffer: commandBuffer,
                        drawableSize: view.drawableSize,
                        currentTime: Float(CACurrentMediaTime() - startTime),
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
            if pass.imageUniformSources.isEmpty == false {
                for source in pass.imageUniformSources {
                    guard let texture = makeRenderTexture(for: view) else {
                        return
                    }
                    if let source {
                        renderPassSource(
                            source,
                            into: texture,
                            commandBuffer: commandBuffer,
                            drawableSize: drawableSize,
                            currentTime: Float(CACurrentMediaTime() - startTime),
                            role: .secondary
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
                time: Float(CACurrentMediaTime() - startTime),
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
                let pipelineState: MTLRenderPipelineState?
                switch role {
                case .primary:
                    pipelineState = primaryPipelineState
                case .secondary:
                    pipelineState = secondaryPipelineState
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
                encodeImagePass(
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
            transitionPipelineState = nil
            layerCompositePipelineState = nil
            feedbackPipelineState = nil
            trailPipelineState = nil
            circlePipelineState = nil
            videoPipelineState = nil
            underwaterPipelineState = nil
            coreImageEffectPipelineState = nil

            guard let device else { return }

            switch configuration {
            case .empty:
                return
            case .single(let pass):
                primaryPipelineState = compileShaderPipeline(source: pass.metalSource, for: view, device: device)
                if pass.imageUniformSources.isEmpty == false {
                    videoPipelineState = compileVideoPipeline(for: view, device: device)
                    for (index, source) in pass.imageUniformSources.enumerated() {
                        guard let source else { continue }
                        compilePipeline(
                            for: source,
                            role: index.isMultiple(of: 2) ? .secondary : .primary,
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

        private enum PipelineRole {
            case primary
            case secondary
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

        private func makeRenderTexture(for view: MTKView) -> MTLTexture? {
            return makeRenderTexture(for: view.drawableSize)
        }

        private func makeRenderTexture(for drawableSize: CGSize) -> MTLTexture? {
            guard let device else { return nil }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: max(Int(drawableSize.width), 1),
                height: max(Int(drawableSize.height), 1),
                mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)
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

        private func offscreenRenderPassDescriptor(for texture: MTLTexture) -> MTLRenderPassDescriptor? {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = texture
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
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
            case .circle(let pass):
                return "circle:\(pass.point?.x ?? -1):\(pass.point?.y ?? -1):\(pass.radius):\(pass.softness):\(pass.color.x):\(pass.color.y):\(pass.color.z):\(pass.color.w)"
            case .clear(let pass):
                return "clear:\(pass.color.x):\(pass.color.y):\(pass.color.z):\(pass.color.w)"
            case .image(let pass):
                return "image:\(pass.nodeID.uuidString)"
            case .videoPlayer(let pass):
                return "videoPlayer:\(pass.nodeID.uuidString)"
            case .video:
                return "video"
            case .coreImage(let pass):
                return "coreimage:\(pass.nodeID.uuidString):\(pass.effect.rawValue):\(pass.primary):\(pass.secondary):\(signature(for: pass.source))"
            case .underwater(let pass):
                return "underwater:\(pass.nodeID.uuidString):\(pass.scale):\(pass.distortion):\(pass.octaves):\(pass.lacunarity):\(pass.gain):\(pass.amplitude):\(pass.textureScale):\(pass.uvClampMargin):\(signature(for: pass.source))"
            case .feedback(let pass):
                return "feedback:\(pass.nodeID.uuidString):\(pass.level):\(pass.blendMode.rawValue):\(signature(for: pass.source))"
            case .mix(let primary, let secondary, _):
                return "mix:\(signature(for: primary)):\(signature(for: secondary))"
            case .transform(let pass):
                return "transform:\(pass.nodeID.uuidString):\(pass.x):\(pass.y):\(pass.z):\(pass.scaleX):\(pass.scaleY):\(pass.rotationDegreesX):\(pass.rotationDegreesY):\(pass.rotationDegreesZ):\(pass.opacity):\(pass.tint.x):\(pass.tint.y):\(pass.tint.z):\(pass.tint.w):\(signature(for: pass.source))"
            case .transition(let pass):
                return "transition:\(pass.style.rawValue):\(pass.progress):\(pass.softness):\(signature(for: pass.primary)):\(signature(for: pass.secondary))"
            case .layers(let layers, let opacity):
                return "layers:\(opacity):\(layers.map { "\(signature(for: $0.source))@\($0.opacity)" }.joined(separator: ":"))"
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
            case .circle(let pass):
                return "circle:\(pass.point?.x ?? -1):\(pass.point?.y ?? -1):\(pass.radius):\(pass.softness):\(pass.color.x):\(pass.color.y):\(pass.color.z):\(pass.color.w)"
            case .clear(let pass):
                return "clear:\(pass.color.x):\(pass.color.y):\(pass.color.z):\(pass.color.w)"
            case .image(let pass):
                return "image:\(pass.nodeID.uuidString)"
            case .videoPlayer(let pass):
                return "videoPlayer:\(pass.nodeID.uuidString)"
            case .video:
                return "video"
            case .coreImage(let pass):
                return "coreimage:\(pass.nodeID.uuidString):\(pass.effect.rawValue):\(pass.primary):\(pass.secondary):\(signature(for: pass.source))"
            case .underwater(let pass):
                return "underwater:\(pass.nodeID.uuidString):\(pass.scale):\(pass.distortion):\(pass.octaves):\(pass.lacunarity):\(pass.gain):\(pass.amplitude):\(pass.textureScale):\(pass.uvClampMargin):\(signature(for: pass.source))"
            case .mix(let primary, let secondary, let amount):
                return "mix:\(amount):\(signature(for: primary)):\(signature(for: secondary))"
            case .transform(let pass):
                return "transform:\(pass.nodeID.uuidString):\(pass.x):\(pass.y):\(pass.z):\(pass.scaleX):\(pass.scaleY):\(pass.rotationDegreesX):\(pass.rotationDegreesY):\(pass.rotationDegreesZ):\(pass.opacity):\(pass.tint.x):\(pass.tint.y):\(pass.tint.z):\(pass.tint.w):\(signature(for: pass.source))"
            case .transition(let pass):
                return "transition:\(pass.style.rawValue):\(pass.progress):\(pass.softness):\(signature(for: pass.primary)):\(signature(for: pass.secondary))"
            case .layers(let layers, let opacity):
                return "layers:\(opacity):\(layers.map { "\(signature(for: $0.source))@\($0.opacity)" }.joined(separator: ":"))"
            case .feedback(let pass):
                return "feedback:\(pass.nodeID.uuidString):\(pass.level):\(pass.blendMode.rawValue):\(signature(for: pass.source))"
            }
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
            float level = clamp(uniforms.level, 0.0, 0.99);
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
        publishMousePosition(event)
        onMouseButtonChange?(leftMouseDown, rightMouseDown)
    }

    override func mouseUp(with event: NSEvent) {
        leftMouseDown = false
        publishMousePosition(event)
        onMouseButtonChange?(leftMouseDown, rightMouseDown)
    }

    override func rightMouseDown(with event: NSEvent) {
        rightMouseDown = true
        publishMousePosition(event)
        onMouseButtonChange?(leftMouseDown, rightMouseDown)
    }

    override func rightMouseUp(with event: NSEvent) {
        rightMouseDown = false
        publishMousePosition(event)
        onMouseButtonChange?(leftMouseDown, rightMouseDown)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = CGPoint(
            x: event.scrollingDeltaX / 600.0,
            y: event.scrollingDeltaY / 600.0
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
