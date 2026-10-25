import CoreGraphics
import Foundation
import ImageIO

/// Made-up pictures for the sample creators: a sky of two colours, a pale sun and a dark hill, different for each
/// creator (`hue`) and each picture (`variant`). Drawn, not photographed, so the app carries no image files and a
/// sample creator can never be mistaken for a real person's work.
enum SampleArt {
    static func jpeg(hue: Double, variant: Int, width: Int, height: Int) -> Data? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        let w = CGFloat(width)
        let h = CGFloat(height)
        let shift = Double(variant) * 0.045

        // The sky, light at the top (the origin is the bottom left).
        let top = color(hue: hue + shift, saturation: 0.45, brightness: 0.95)
        let bottom = color(hue: hue + shift + 0.07, saturation: 0.75, brightness: 0.55)
        if let sky = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(sky, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
        }

        // A pale sun, higher or lower and left or right for each picture.
        let sunSize = w * (0.28 + 0.03 * CGFloat(variant % 3))
        let sunX = w * (0.25 + 0.17 * CGFloat(variant % 4))
        let sunY = h * (0.58 + 0.07 * CGFloat(variant % 3))
        context.setFillColor(color(hue: hue + shift - 0.03, saturation: 0.15, brightness: 1).copy(alpha: 0.6) ?? top)
        context.fillEllipse(in: CGRect(x: sunX - sunSize / 2, y: sunY - sunSize / 2, width: sunSize, height: sunSize))

        // A hill in front, darker, with a different swell each time.
        let rise = h * (0.22 + 0.04 * CGFloat(variant % 3))
        let hill = CGMutablePath()
        hill.move(to: CGPoint(x: 0, y: 0))
        hill.addLine(to: CGPoint(x: 0, y: rise))
        hill.addCurve(
            to: CGPoint(x: w, y: rise * 0.7),
            control1: CGPoint(x: w * 0.3, y: rise * (1.5 + 0.1 * CGFloat(variant % 2))),
            control2: CGPoint(x: w * 0.65, y: rise * 0.2)
        )
        hill.addLine(to: CGPoint(x: w, y: 0))
        hill.closeSubpath()
        context.addPath(hill)
        context.setFillColor(color(hue: hue + shift + 0.1, saturation: 0.8, brightness: 0.22))
        context.fillPath()

        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Hue, saturation and brightness (each 0 to 1; hue wraps) as a colour.
    private static func color(hue: Double, saturation: Double, brightness: Double) -> CGColor {
        let wrapped = hue - hue.rounded(.down)
        let sector = wrapped * 6
        let index = Int(sector) % 6
        let fraction = sector - Double(Int(sector))
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - fraction * saturation)
        let t = brightness * (1 - (1 - fraction) * saturation)
        let rgb: (Double, Double, Double)
        switch index {
        case 0: rgb = (brightness, t, p)
        case 1: rgb = (q, brightness, p)
        case 2: rgb = (p, brightness, t)
        case 3: rgb = (p, q, brightness)
        case 4: rgb = (t, p, brightness)
        default: rgb = (brightness, p, q)
        }
        return CGColor(red: CGFloat(rgb.0), green: CGFloat(rgb.1), blue: CGFloat(rgb.2), alpha: 1)
    }
}
