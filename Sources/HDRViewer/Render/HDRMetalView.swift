import CoreImage
import MetalKit
import QuartzCore
import SwiftUI

struct HDRMetalView: NSViewRepresentable {
    let ciImage: CIImage
    let zoomScale: CGFloat
    let panOffset: CGSize

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        let device = MTLCreateSystemDefaultDevice()!
        view.device = device
        // rgba16Float gives full half-float precision for EDR values well above 1.0
        view.colorPixelFormat = .rgba16Float
        view.framebufferOnly = false
        view.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator

        // Force the backing CAMetalLayer to support EDR/XDR output
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.pixelFormat = .rgba16Float
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            metalLayer.wantsExtendedDynamicRangeContent = true
        }

        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.ciImage = ciImage
        context.coordinator.zoomScale = zoomScale
        context.coordinator.panOffset = panOffset
        nsView.setNeedsDisplay(nsView.bounds)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var ciImage: CIImage?
        var zoomScale: CGFloat = 1.0
        var panOffset: CGSize = .zero

        private var ciContext: CIContext?
        private var commandQueue: MTLCommandQueue?

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        }

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable else { return }

            if ciContext == nil, let device = view.device {
                let edrColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
                ciContext = CIContext(mtlDevice: device, options: [
                    .workingFormat: CIFormat.RGBAh,
                    .workingColorSpace: edrColorSpace,
                    .outputColorSpace: edrColorSpace
                ])
                commandQueue = device.makeCommandQueue()
            }

            guard
                let ciContext,
                let commandQueue,
                let commandBuffer = commandQueue.makeCommandBuffer()
            else {
                return
            }

            let renderPass = MTLRenderPassDescriptor()
            renderPass.colorAttachments[0].texture = drawable.texture
            renderPass.colorAttachments[0].loadAction = .clear
            renderPass.colorAttachments[0].storeAction = .store
            renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            let clearEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass)
            clearEncoder?.endEncoding()

            // Use the EDR-capable extended linear P3 colorspace.
            // Values > 1.0 will drive the display above SDR white (XDR headroom).
            let edrColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

            if let ciImage {
                let bounds = CGRect(origin: .zero, size: view.drawableSize)
                let transformedImage = fitTransformedImage(ciImage, into: bounds.size)

                ciContext.render(
                    transformedImage,
                    to: drawable.texture,
                    commandBuffer: commandBuffer,
                    bounds: bounds,
                    colorSpace: edrColorSpace
                )
            }

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        private func fitTransformedImage(_ image: CIImage, into size: CGSize) -> CIImage {
            let extent = image.extent
            let imageWidth = max(extent.width, 1)
            let imageHeight = max(extent.height, 1)
            let viewWidth = max(size.width, 1)
            let viewHeight = max(size.height, 1)

            let fitScale = min(viewWidth / imageWidth, viewHeight / imageHeight)
            let scale = max(fitScale * zoomScale, 0.01)
            let scaledWidth = imageWidth * scale
            let scaledHeight = imageHeight * scale

            let translateX = (viewWidth - scaledWidth) * 0.5 + panOffset.width
            let translateY = (viewHeight - scaledHeight) * 0.5 + panOffset.height

            let transform = CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: translateX / scale, y: translateY / scale)

            return image.transformed(by: transform)
        }
    }
}
