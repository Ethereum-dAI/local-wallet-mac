import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outputDirectory = repoRoot
    .appendingPathComponent("wallet-macos/App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let icons: [(name: String, points: Int, scale: Int)] = [
    ("AppIcon-16.png", 16, 1),
    ("AppIcon-16@2x.png", 16, 2),
    ("AppIcon-32.png", 32, 1),
    ("AppIcon-32@2x.png", 32, 2),
    ("AppIcon-128.png", 128, 1),
    ("AppIcon-128@2x.png", 128, 2),
    ("AppIcon-256.png", 256, 1),
    ("AppIcon-256@2x.png", 256, 2),
    ("AppIcon-512.png", 512, 1),
    ("AppIcon-512@2x.png", 512, 2),
]

func rgba(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func saveIcon(named name: String, pixels: Int) throws {
    let width = pixels
    let height = pixels
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "GenerateAppIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGContext"])
    }

    let px = CGFloat(pixels)
    let full = CGRect(x: 0, y: 0, width: px, height: px)

    context.setFillColor(rgba(15, 20, 20))
    context.addPath(roundedRect(full, radius: px * 0.22))
    context.fillPath()

    let glow = CGRect(x: px * 0.46, y: px * 0.08, width: px * 0.82, height: px * 0.82)
    context.setFillColor(rgba(145, 218, 190, 0.34))
    context.fillEllipse(in: glow)

    let card = full.insetBy(dx: px * 0.14, dy: px * 0.18)
    context.setFillColor(rgba(236, 242, 234, 0.12))
    context.addPath(roundedRect(card, radius: px * 0.08))
    context.fillPath()
    context.setStrokeColor(rgba(236, 242, 234, 0.30))
    context.setLineWidth(max(1, px * 0.012))
    context.addPath(roundedRect(card, radius: px * 0.08))
    context.strokePath()

    context.setFillColor(rgba(244, 245, 241))
    context.fill(CGRect(x: px * 0.23, y: px * 0.27, width: px * 0.06, height: px * 0.28))
    context.fill(CGRect(x: px * 0.23, y: px * 0.27, width: px * 0.20, height: px * 0.06))
    context.fill(CGRect(x: px * 0.48, y: px * 0.27, width: px * 0.06, height: px * 0.28))
    context.fill(CGRect(x: px * 0.64, y: px * 0.27, width: px * 0.06, height: px * 0.28))

    context.setStrokeColor(rgba(244, 245, 241))
    context.setLineWidth(max(1.4, px * 0.052))
    context.setLineCap(.round)
    context.move(to: CGPoint(x: px * 0.51, y: px * 0.53))
    context.addLine(to: CGPoint(x: px * 0.59, y: px * 0.30))
    context.addLine(to: CGPoint(x: px * 0.67, y: px * 0.53))
    context.strokePath()

    context.setStrokeColor(rgba(199, 248, 211))
    context.setLineWidth(max(1.5, px * 0.026))
    context.strokeEllipse(in: CGRect(x: px * 0.59, y: px * 0.58, width: px * 0.15, height: px * 0.15))
    context.move(to: CGPoint(x: px * 0.70, y: px * 0.61))
    context.addLine(to: CGPoint(x: px * 0.83, y: px * 0.48))
    context.addLine(to: CGPoint(x: px * 0.79, y: px * 0.44))
    context.move(to: CGPoint(x: px * 0.77, y: px * 0.54))
    context.addLine(to: CGPoint(x: px * 0.84, y: px * 0.54))
    context.strokePath()

    guard let image = context.makeImage() else {
        throw NSError(domain: "GenerateAppIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGImage"])
    }

    let destinationURL = outputDirectory.appendingPathComponent(name) as CFURL
    guard let destination = CGImageDestinationCreateWithURL(destinationURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "GenerateAppIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create image destination"])
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "GenerateAppIcon", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to write \(name)"])
    }
}

for icon in icons {
    try saveIcon(named: icon.name, pixels: icon.points * icon.scale)
}

print("Generated app icons in \(outputDirectory.path)")
