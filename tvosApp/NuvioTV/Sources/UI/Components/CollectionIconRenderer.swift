import UIKit
import CoreImage

/// Shared 160px raster for a 40pt icon: sharp through focus scaling, with the
/// same aspect-preserving circle composition in the sidebar and Home badge.
@MainActor
enum CollectionIconRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func render(_ image: UIImage, style: CollectionServiceIcon?, sourceURL: String? = nil) -> UIImage {
        let bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 4
        format.opaque = false
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            let circle = UIBezierPath(ovalIn: bounds)
            let rgb = style?.backgroundRGB ?? 0x1F1F1F
            UIColor(red: CGFloat((rgb >> 16) & 255) / 255,
                    green: CGFloat((rgb >> 8) & 255) / 255,
                    blue: CGFloat(rgb & 255) / 255, alpha: 1).setFill()
            circle.fill()
            context.cgContext.saveGState()
            circle.addClip()
            // Full-bleed is reserved for known square provider icons. Wide
            // logos/custom images fit in a safe inset, without distortion.
            let square = abs(image.size.width - image.size.height) <= 1
            let target = style?.fillsCircle == true && square
                ? bounds : bounds.insetBy(dx: style == nil ? 5 : 3, dy: style == nil ? 5 : 3)
            let scale = min(target.width / max(1, image.size.width), target.height / max(1, image.size.height))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            context.cgContext.interpolationQuality = .high
            let artwork = sourceURL == CollectionServiceIcon.primeBlueURL && style?.fillsCircle == true
                ? whitePrimeWordmark(image) : image
            artwork.draw(in: CGRect(x: target.midX - size.width / 2, y: target.midY - size.height / 2,
                                  width: size.width, height: size.height))
            context.cgContext.restoreGState()
            UIColor.white.withAlphaComponent(0.12).setStroke()
            let border = UIBezierPath(ovalIn: bounds.insetBy(dx: 0.25, dy: 0.25))
            border.lineWidth = 0.5
            border.stroke()
        }
    }

    /// This registered asset has a black wordmark on saturated blue. Derive
    /// coverage from its blue channel and draw the original shapes in white;
    /// never apply this treatment to a configured/custom or fallback image.
    private static func whitePrimeWordmark(_ image: UIImage) -> UIImage {
        guard let input = CIImage(image: image) else { return image }
        let mask = input.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: -1.1, w: 0),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 1.1)
        ])
        guard let result = context.createCGImage(mask, from: input.extent) else { return image }
        return UIImage(cgImage: result, scale: image.scale, orientation: .up)
    }
}
