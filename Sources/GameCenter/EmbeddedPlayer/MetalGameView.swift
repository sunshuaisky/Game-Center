import AppKit
import CoreHostIPC
import Metal
import MetalKit
import SwiftUI

private let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut gc_vertex_main(
    uint vertexID [[vertex_id]],
    constant float4 &viewportRect [[buffer(0)]]
) {
    // viewportRect = (minX, minY, maxX, maxY) in NDC [-1, 1]
    float2 positions[4] = {
        float2(viewportRect.x, viewportRect.y),
        float2(viewportRect.z, viewportRect.y),
        float2(viewportRect.x, viewportRect.w),
        float2(viewportRect.z, viewportRect.w)
    };
    float2 uvs[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = uvs[vertexID];
    return out;
}

fragment float4 gc_fragment_main(
    VertexOut in [[stage_in]],
    texture2d<float> frameTexture [[texture(0)]],
    sampler frameSampler [[sampler(0)]]
) {
    return float4(frameTexture.sample(frameSampler, in.texCoord).rgb, 1.0);
}
"""

final class InteractiveMetalView: MTKView {
    var onPointerAndMouse: (((Double, Double, Bool)?, UInt8, Int32, Int32, Int32) -> Void)?
    var onMouseHoverTop: ((Bool) -> Void)?
    var gameContentRect: CGRect = .zero

    private var trackingAreaRef: NSTrackingArea?
    private var buttonMask: UInt8 = 0
    private var lastHoverTop = false

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let inTopZone = point.y >= bounds.height - 68
        if inTopZone != lastHoverTop {
            lastHoverTop = inTopZone
            onMouseHoverTop?(inTopZone)
        }
        let (nx, ny, inside) = normalizeToGameRect(point)
        let dx = Int32(event.deltaX.rounded())
        let dy = Int32(event.deltaY.rounded())
        let pointer: (Double, Double, Bool)? = inside ? (nx, ny, (buttonMask & 1) != 0) : nil
        if pointer != nil || dx != 0 || dy != 0 {
            onPointerAndMouse?(pointer, buttonMask, dx, dy, 0)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if lastHoverTop {
            lastHoverTop = false
            onMouseHoverTop?(false)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        buttonMask |= 1
        let pointer = pointerPayload(event, pressed: true)
        onPointerAndMouse?(pointer, buttonMask, 0, 0, 0)
    }

    override func mouseDragged(with event: NSEvent) {
        let pointer = pointerPayload(event, pressed: true)
        onPointerAndMouse?(pointer, buttonMask, Int32(event.deltaX.rounded()), Int32(event.deltaY.rounded()), 0)
    }

    override func mouseUp(with event: NSEvent) {
        buttonMask &= ~1
        let pointer = pointerPayload(event, pressed: false)
        onPointerAndMouse?(pointer, buttonMask, 0, 0, 0)
    }

    override func rightMouseDown(with event: NSEvent) {
        buttonMask |= 2
        onPointerAndMouse?(nil, buttonMask, 0, 0, 0)
    }

    override func rightMouseDragged(with event: NSEvent) {
        onPointerAndMouse?(nil, buttonMask, Int32(event.deltaX.rounded()), Int32(event.deltaY.rounded()), 0)
    }

    override func rightMouseUp(with event: NSEvent) {
        buttonMask &= ~2
        onPointerAndMouse?(nil, buttonMask, 0, 0, 0)
    }

    override func otherMouseDown(with event: NSEvent) {
        buttonMask |= 4
        onPointerAndMouse?(nil, buttonMask, 0, 0, 0)
    }

    override func otherMouseUp(with event: NSEvent) {
        buttonMask &= ~4
        onPointerAndMouse?(nil, buttonMask, 0, 0, 0)
    }

    override func scrollWheel(with event: NSEvent) {
        let wy = Int32(event.scrollingDeltaY.rounded())
        if wy != 0 {
            onPointerAndMouse?(nil, buttonMask, 0, 0, wy)
        }
    }

    private func pointerPayload(_ event: NSEvent, pressed: Bool) -> (Double, Double, Bool) {
        let point = convert(event.locationInWindow, from: nil)
        let (nx, ny, inside) = normalizeToGameRect(point)
        return (nx, ny, pressed && inside)
    }

    private func normalizeToGameRect(_ viewPoint: NSPoint) -> (Double, Double, Bool) {
        let rect = gameContentRect.width > 1 && gameContentRect.height > 1 ? gameContentRect : bounds
        guard rect.width > 0, rect.height > 0 else { return (0.5, 0.5, false) }
        // NSView has bottom-left origin; Libretro pointer expects top-left (0,0) -> (1,1).
        let nx = Double((viewPoint.x - rect.minX) / rect.width)
        let ny = Double(1.0 - (viewPoint.y - rect.minY) / rect.height)
        let inside = (0.0...1.0).contains(nx) && (0.0...1.0).contains(ny)
        return (min(max(nx, 0.0), 1.0), min(max(ny, 0.0), 1.0), inside)
    }
}

struct MetalGameView: NSViewRepresentable {
    let frameRing: SharedFrameRing
    let crispPixels: Bool
    let isPaused: Bool
    let onPointerAndMouse: ((Double, Double, Bool)?, UInt8, Int32, Int32, Int32) -> Void
    let onMouseHoverTop: (Bool) -> Void

    func makeCoordinator() -> Renderer {
        Renderer(frameRing: frameRing)
    }

    func makeNSView(context: Context) -> InteractiveMetalView {
        let view = InteractiveMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 120
        view.isPaused = isPaused
        view.enableSetNeedsDisplay = false
        view.delegate = context.coordinator
        context.coordinator.crispPixels = crispPixels
        context.coordinator.configure(device: view.device, view: view)
        updateCallbacks(view: view)
        return view
    }

    func updateNSView(_ view: InteractiveMetalView, context: Context) {
        let coordinator = context.coordinator
        let filterChanged = coordinator.crispPixels != crispPixels
        coordinator.crispPixels = crispPixels
        if coordinator.frameRing !== frameRing {
            coordinator.frameRing = frameRing
            coordinator.resetForNewRing()
        }
        if filterChanged {
            coordinator.markNeedsRedraw()
        }
        if view.isPaused != isPaused {
            view.isPaused = isPaused
            if !isPaused {
                coordinator.markNeedsRedraw()
            }
        }
        updateCallbacks(view: view)
        if isPaused && filterChanged {
            view.draw()
        }
    }

    private func updateCallbacks(view: InteractiveMetalView) {
        view.onPointerAndMouse = onPointerAndMouse
        view.onMouseHoverTop = onMouseHoverTop
    }

    final class Renderer: NSObject, MTKViewDelegate {
        private static let maxInFlightFrames = 3

        var frameRing: SharedFrameRing
        var crispPixels = true

        private var device: MTLDevice?
        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private var nearestSampler: MTLSamplerState?
        private var linearSampler: MTLSamplerState?
        private var textures: [MTLTexture] = []
        private var textureIndex = 0
        private var activeTexture: MTLTexture?
        private var textureWidth = 0
        private var textureHeight = 0
        private var aspectRatio: Float = 4.0 / 3.0
        private var lastSequence: UInt64 = 0
        private var needsRedraw = true
        private let frameSemaphore = DispatchSemaphore(value: maxInFlightFrames)

        init(frameRing: SharedFrameRing) {
            self.frameRing = frameRing
        }

        func markNeedsRedraw() {
            needsRedraw = true
        }

        func resetForNewRing() {
            lastSequence = 0
            needsRedraw = true
        }

        func configure(device: MTLDevice?, view: MTKView) {
            guard let device else { return }
            self.device = device
            self.commandQueue = device.makeCommandQueue()

            do {
                let library = try device.makeLibrary(source: metalShaderSource, options: nil)
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = library.makeFunction(name: "gc_vertex_main")
                desc.fragmentFunction = library.makeFunction(name: "gc_fragment_main")
                desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
                pipelineState = try device.makeRenderPipelineState(descriptor: desc)
            } catch {
                NSLog("Game Center Metal pipeline failed: %@", error.localizedDescription)
            }

            let nearestDesc = MTLSamplerDescriptor()
            nearestDesc.minFilter = .nearest
            nearestDesc.magFilter = .nearest
            nearestSampler = device.makeSamplerState(descriptor: nearestDesc)

            let linearDesc = MTLSamplerDescriptor()
            linearDesc.minFilter = .linear
            linearDesc.magFilter = .linear
            linearSampler = device.makeSamplerState(descriptor: linearDesc)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            needsRedraw = true
            if view.isPaused {
                view.draw()
            }
        }

        private func ensureTextures(device: MTLDevice, width: Int, height: Int) {
            guard textures.isEmpty || textureWidth != width || textureHeight != height else { return }
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            textures = (0..<Self.maxInFlightFrames).compactMap { _ in device.makeTexture(descriptor: desc) }
            textureIndex = 0
            textureWidth = width
            textureHeight = height
        }

        func draw(in view: MTKView) {
            guard let device,
                  let commandQueue,
                  let pipelineState else { return }

            let latest = frameRing.latestFrame(after: lastSequence)
            if latest == nil && !needsRedraw {
                return
            }

            // Wait for an available texture slot before uploading pixels or acquiring a drawable.
            guard frameSemaphore.wait(timeout: .now() + .milliseconds(4)) == .success else { return }

            if let latest,
               let pixelPtr = frameRing.pixelBufferPointer(slotIndex: latest.slotIndex) {
                lastSequence = latest.sequence
                aspectRatio = latest.aspectRatio > 0.05 ? latest.aspectRatio : (Float(latest.width) / Float(max(latest.height, 1)))
                ensureTextures(device: device, width: latest.width, height: latest.height)
                if !textures.isEmpty {
                    let target = textures[textureIndex]
                    textureIndex = (textureIndex + 1) % textures.count
                    let region = MTLRegionMake2D(0, 0, latest.width, latest.height)
                    target.replace(region: region, mipmapLevel: 0, withBytes: pixelPtr, bytesPerRow: latest.bytesPerRow)
                    activeTexture = target
                }
            }

            guard let renderPass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
                frameSemaphore.signal()
                return
            }

            needsRedraw = false

            if let texture = activeTexture {
                let viewW = max(Float(view.drawableSize.width), 1)
                let viewH = max(Float(view.drawableSize.height), 1)
                let viewAspect = viewW / viewH
                let targetAspect = max(aspectRatio, 0.1)

                let scaleX: Float
                let scaleY: Float
                if viewAspect > targetAspect {
                    scaleX = targetAspect / viewAspect
                    scaleY = 1.0
                } else {
                    scaleX = 1.0
                    scaleY = viewAspect / targetAspect
                }

                if let interactive = view as? InteractiveMetalView {
                    let b = interactive.bounds
                    let contentW = b.width * CGFloat(scaleX)
                    let contentH = b.height * CGFloat(scaleY)
                    interactive.gameContentRect = CGRect(
                        x: (b.width - contentW) * 0.5,
                        y: (b.height - contentH) * 0.5,
                        width: contentW,
                        height: contentH
                    )
                }

                var rect = SIMD4<Float>(-scaleX, -scaleY, scaleX, scaleY)
                encoder.setRenderPipelineState(pipelineState)
                encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.setFragmentSamplerState(crispPixels ? nearestSampler : linearSampler, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }

            encoder.endEncoding()
            let semaphore = frameSemaphore
            commandBuffer.addCompletedHandler { _ in
                semaphore.signal()
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
