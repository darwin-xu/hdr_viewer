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
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra10_xr
        view.framebufferOnly = false
        view.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator

        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.pixelFormat = .bgra10_xr
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
                ciContext = CIContext(mtlDevice: device, options: [
                    .workingFormat: CIFormat.RGBAh,
                    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) as Any
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
            renderPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass)
            encoder?.endEncoding()

            if let ciImage {
                let bounds = CGRect(origin: .zero, size: view.drawableSize)
                let transformedImage = fitTransformedImage(ciImage, into: bounds.size)

                let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
                    ?? CGColorSpace(name: CGColorSpace.displayP3)
                    ?? CGColorSpaceCreateDeviceRGB()

                ciContext.render(
                    transformedImage,
                    to: drawable.texture,
                    commandBuffer: commandBuffer,
                    bounds: bounds,
                    colorSpace: colorSpace
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
