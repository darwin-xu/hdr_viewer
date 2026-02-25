import CoreImage
import MetalKit
import QuartzCore
import SwiftUI

struct HDRMetalView: NSViewRepresentable {
    let ciImage: CIImage
    let zoomScale: CGFloat
    let panOffset: CGSize
    let boostMode: HDRBoostMode
    let boostIntensity: Double

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
        context.coordinator.boostMode = boostMode
        context.coordinator.boostIntensity = boostIntensity
        nsView.setNeedsDisplay(nsView.bounds)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var ciImage: CIImage?
        var zoomScale: CGFloat = 1.0
        var panOffset: CGSize = .zero
        var boostMode: HDRBoostMode = .none
        var boostIntensity: Double = 0.45

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
                let boostedImage = applyHDRBoostIfNeeded(to: ciImage)
                let transformedImage = fitTransformedImage(boostedImage, into: bounds.size)

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

        private func applyHDRBoostIfNeeded(to image: CIImage) -> CIImage {
            guard boostMode != .none else { return image }

            let clampedIntensity = min(max(boostIntensity, 0), 1)

            // Threshold below which pixels are completely untouched.
            // Headroom = how bright the brightest highlights become (multiples of SDR white).
            let threshold: Double
            let headroom: Double

            switch boostMode {
            case .none:
                return image
            case .sdr:
                threshold = 0.85
                headroom = 1.5 + (clampedIntensity * 2.0)   // 1.5x – 3.5x SDR white
            case .raw:
                threshold = 0.75
                headroom = 1.8 + (clampedIntensity * 2.5)   // 1.8x – 4.3x SDR white
            }

            // --- Step 1: Create luminance image (grayscale) ---
            // All RGB channels become Rec.709 luminance so we can threshold on brightness.
            let luminance = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
            ])

            // --- Step 2: Create highlight mask from luminance ---
            // Below threshold → 0 (use original pixel).
            // Above threshold → ramp smoothly to 1.0 (use boosted pixel).
            // CIToneCurve is fine here because luminance image has R=G=B (no color shift).
            let midRamp = threshold + (1.0 - threshold) * 0.5
            let highlightMask = luminance.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0.0, y: 0.0),
                "inputPoint1": CIVector(x: CGFloat(threshold * 0.5), y: 0.0),
                "inputPoint2": CIVector(x: CGFloat(threshold), y: 0.0),
                "inputPoint3": CIVector(x: CGFloat(midRamp), y: 0.5),
                "inputPoint4": CIVector(x: 1.0, y: 1.0)
            ])

            // --- Step 3: Create exposure-boosted copy ---
            // CIExposureAdjust scales R, G, B by the same factor (2^EV),
            // so color ratios are perfectly preserved — no hue/saturation shift.
            let ev = log2(headroom)
            let boostedImage = image.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: ev
            ])

            // --- Step 4: Blend using mask ---
            // Where mask = 0 (darks/mids): output = original (untouched).
            // Where mask = 1 (highlights): output = boosted (EDR headroom).
            // Smooth transition in between.
            let result = boostedImage.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: image,
                kCIInputMaskImageKey: highlightMask
            ])

            return result
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
