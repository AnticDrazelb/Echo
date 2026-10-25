import CoreImage
import UIKit

/// Media a composition draws on, at the resolution being rendered.
struct StudioAssets {
    var baseStats: StyleDNA = .neutral
    /// Vision masks for the base (photos only), in base-image coordinates.
    var sky: CIImage?
    var skin: CIImage?
    var subject: CIImage?
    /// Overlay images by file name.
    var images: [String: CIImage] = [:]
}

/// Builds the Core Image graph for a composition at time t.
/// Positions and sizes are stored relative to the canvas, so the same
/// project renders identically at preview and export resolution.
enum CompositionRenderer {
    static func render(_ comp: Composition, base: CIImage, at t: Double, assets: StudioAssets, renderers: RendererCache) -> CIImage {
        let canvas = base.extent
        let ctx = EffectContext(
            canvas: canvas, time: t, baseStats: assets.baseStats,
            subjectMask: assets.subject.map { fit($0, to: canvas) }, renderers: renderers
        )
        var acc = CIImage(color: .black).cropped(to: canvas)

        for layer in comp.layers where layer.isActive(at: t) {
            let opacity = max(0, min(1, layer.opacity.at(t)))
            guard opacity > 0.001 else { continue }
            let mask = maskImage(layer.mask, canvas: canvas, t: t, below: acc, assets: assets)

            if layer.isAdjustment {
                var adjusted = acc
                for effect in layer.effects { adjusted = EffectRenderer.apply(effect, to: adjusted, ctx: ctx) }
                let amount = (mask ?? CIImage(color: .white).cropped(to: canvas)).applyingFilter("CIColorMatrix", parameters: scaleRGB(opacity))
                acc = adjusted.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: acc, kCIInputMaskImageKey: amount,
                ]).cropped(to: canvas)
                continue
            }

            guard var image = content(layer, base: base, canvas: canvas, t: t, assets: assets) else { continue }
            for effect in layer.effects { image = EffectRenderer.apply(effect, to: image, ctx: ctx) }
            if let mask {
                image = image.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
                ])
            }
            if opacity < 0.999 {
                image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
            }
            image = image.cropped(to: canvas)
            if layer.blend == .normal {
                acc = image.composited(over: acc)
            } else {
                acc = image.applyingFilter(layer.blend.filterName, parameters: [kCIInputBackgroundImageKey: acc])
            }
            acc = acc.cropped(to: canvas)
        }
        return acc
    }

    // MARK: Layer content

    private static func content(_ layer: Layer, base: CIImage, canvas: CGRect, t: Double, assets: StudioAssets) -> CIImage? {
        let w = canvas.width, h = canvas.height
        switch layer.content {
        case .base:
            return place(base, centeredAt: CGPoint(x: canvas.midX, y: canvas.midY), layer: layer, canvas: canvas, t: t, recenter: true)

        case .adjustment:
            return nil

        case .solid(let color):
            let (r, g, b) = color.at(t)
            return CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: canvas)

        case .gradient(let grad):
            let (r0, g0, b0) = grad.from.at(t)
            let (r1, g1, b1) = grad.to.at(t)
            let angle = grad.angle.at(t) * .pi / 180
            let half = max(w, h) / 2
            let dx = cos(angle) * half, dy = sin(angle) * half
            return CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: canvas.midX - dx, y: canvas.midY - dy),
                "inputPoint1": CIVector(x: canvas.midX + dx, y: canvas.midY + dy),
                "inputColor0": CIColor(red: r0, green: g0, blue: b0),
                "inputColor1": CIColor(red: r1, green: g1, blue: b1),
            ])?.outputImage?.cropped(to: canvas)

        case .text(let text):
            guard let image = textImage(text, width: w, t: t) else { return nil }
            return place(image, centeredAt: .zero, layer: layer, canvas: canvas, t: t, recenter: false)

        case .shape(let shape):
            let sw = shape.width.at(t) * w, sh = shape.height.at(t) * w
            let (r, g, b) = shape.color.at(t)
            let color = CIColor(red: r, green: g, blue: b)
            let image: CIImage?
            switch shape.kind {
            case .rectangle:
                image = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                    "inputExtent": CIVector(x: -sw / 2, y: -sh / 2, z: sw, w: sh),
                    "inputRadius": min(shape.cornerRadius.at(t) * w, min(sw, sh) / 2),
                    "inputColor": color,
                ])?.outputImage
            case .ellipse:
                let radius = max(sw, 1) / 2
                image = CIFilter(name: "CIRadialGradient", parameters: [
                    "inputCenter": CIVector(x: 0, y: 0),
                    "inputRadius0": max(radius - 1.5, 0),
                    "inputRadius1": radius,
                    "inputColor0": color,
                    "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
                ])?.outputImage?
                    .cropped(to: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
                    .transformed(by: CGAffineTransform(scaleX: 1, y: sh / max(sw, 1)))
            }
            return image.flatMap { place($0, centeredAt: .zero, layer: layer, canvas: canvas, t: t, recenter: false) }

        case .image(let file):
            guard let source = assets.images[file] else { return nil }
            // Overlays start at 60% of the canvas width.
            let s = w * 0.6 / max(source.extent.width, 1)
            let sized = source.normalizedToOrigin()
                .transformed(by: CGAffineTransform(scaleX: s, y: s))
            let centered = sized.transformed(by: CGAffineTransform(translationX: -sized.extent.midX, y: -sized.extent.midY))
            return place(centered, centeredAt: .zero, layer: layer, canvas: canvas, t: t, recenter: false)
        }
    }

    /// Applies the layer transform. Content is centred at `origin` and moved
    /// to (x, y) in canvas space (y measured from the top).
    private static func place(_ image: CIImage, centeredAt origin: CGPoint, layer: Layer, canvas: CGRect, t: Double, recenter: Bool) -> CIImage {
        let tr = layer.transform
        let scale = CGFloat(max(0.01, tr.scale.at(t)))
        let rotation = CGFloat(tr.rotation.at(t) * .pi / 180)
        let target = CGPoint(
            x: canvas.minX + CGFloat(tr.x.at(t)) * canvas.width,
            y: canvas.maxY - CGFloat(tr.y.at(t)) * canvas.height
        )
        let m = CGAffineTransform(translationX: -origin.x, y: -origin.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(rotationAngle: -rotation))
            .concatenating(CGAffineTransform(translationX: target.x, y: target.y))
        let moved = image.transformed(by: m)
        return moved.cropped(to: canvas)
    }

    static func textImage(_ text: TextContent, width: CGFloat, t: Double) -> CIImage? {
        guard !text.text.isEmpty else { return nil }
        let size = max(4, text.size.at(t) * width)
        let weight = UIFont.Weight(rawValue: CGFloat(text.weight))
        var font: UIFont
        switch text.font {
        case .condensed:
            font = UIFont.systemFont(ofSize: size, weight: weight, width: .condensed)
        default:
            font = UIFont.systemFont(ofSize: size, weight: weight)
            let design: UIFontDescriptor.SystemDesign = text.font == .rounded ? .rounded
                : text.font == .serif ? .serif : text.font == .mono ? .monospaced : .default
            if let descriptor = font.fontDescriptor.withDesign(design) {
                font = UIFont(descriptor: descriptor, size: size)
            }
        }
        let (r, g, b) = text.color.at(t)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(red: r, green: g, blue: b, alpha: 1),
            .kern: text.tracking.at(t) * size,
        ]
        let shadowAmount = text.shadow.at(t)
        if shadowAmount > 0.01 {
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(min(0.9, shadowAmount))
            shadow.shadowBlurRadius = size * 0.18
            shadow.shadowOffset = CGSize(width: 0, height: size * 0.04)
            attributes[.shadow] = shadow
        }
        let string = NSAttributedString(string: text.text, attributes: attributes)
        guard let image = CIFilter(name: "CIAttributedTextImageGenerator", parameters: [
            "inputText": string, "inputScaleFactor": 1.0,
        ])?.outputImage else { return nil }
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.midX, y: -image.extent.midY))
    }

    // MARK: Masks

    static func maskImage(_ mask: LayerMask, canvas: CGRect, t: Double, below: CIImage, assets: StudioAssets) -> CIImage? {
        let w = canvas.width, h = canvas.height
        let center = CGPoint(x: canvas.minX + CGFloat(mask.x.at(t)) * w, y: canvas.maxY - CGFloat(mask.y.at(t)) * h)
        let feather = CGFloat(max(0, min(1, mask.feather.at(t))))
        var image: CIImage?

        switch mask.kind {
        case .none:
            return nil
        case .ellipse:
            let rx = max(2, CGFloat(mask.width.at(t)) * w / 2)
            let ry = max(2, CGFloat(mask.height.at(t)) * h / 2)
            image = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 0, y: 0),
                "inputRadius0": rx * (1 - feather),
                "inputRadius1": rx,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0),
            ])?.outputImage?
                .transformed(by: CGAffineTransform(scaleX: 1, y: ry / rx))
                .transformed(by: CGAffineTransform(translationX: center.x, y: center.y))
        case .rectangle:
            let rw = max(2, CGFloat(mask.width.at(t)) * w), rh = max(2, CGFloat(mask.height.at(t)) * h)
            let rect = CIImage(color: .white).cropped(to: CGRect(x: center.x - rw / 2, y: center.y - rh / 2, width: rw, height: rh))
            let soft = feather > 0.001 ? rect.applyingGaussianBlur(sigma: feather * min(rw, rh) * 0.3) : rect
            image = soft.composited(over: CIImage(color: .black))
        case .linear:
            let angle = mask.angle.at(t) * .pi / 180
            let reach = max(2, feather * max(w, h) / 2)
            let dx = cos(angle) * reach, dy = sin(angle) * reach
            image = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: center.x - dx, y: center.y - dy),
                "inputPoint1": CIVector(x: center.x + dx, y: center.y + dy),
                "inputColor0": CIColor(red: 0, green: 0, blue: 0),
                "inputColor1": CIColor(red: 1, green: 1, blue: 1),
            ])?.outputImage
        case .luminance:
            let low = CGFloat(mask.low.at(t)), high = max(CGFloat(mask.high.at(t)), low + 0.01)
            let k = 1 / (high - low)
            let luma = CIVector(x: 0.2126 * k, y: 0.7152 * k, z: 0.0722 * k, w: 0)
            image = below.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": luma, "inputGVector": luma, "inputBVector": luma,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: -low * k, y: -low * k, z: -low * k, w: 1),
            ]).applyingFilter("CIColorClamp")
        case .sky:
            image = assets.sky.map { fit($0, to: canvas) }
        case .skin:
            image = assets.skin.map { fit($0, to: canvas) }
        case .subject:
            image = assets.subject.map { fit($0, to: canvas) }
        }
        guard var result = image?.cropped(to: canvas) else { return nil }
        if mask.inverted { result = result.applyingFilter("CIColorInvert") }
        return result.cropped(to: canvas)
    }

    static func fit(_ image: CIImage, to canvas: CGRect) -> CIImage {
        let ext = image.extent
        guard ext.width > 0, ext.height > 0 else { return image }
        return image
            .transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
            .transformed(by: CGAffineTransform(scaleX: canvas.width / ext.width, y: canvas.height / ext.height))
            .transformed(by: CGAffineTransform(translationX: canvas.minX, y: canvas.minY))
    }

    private static func scaleRGB(_ k: Double) -> [String: Any] {
        [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]
    }
}
