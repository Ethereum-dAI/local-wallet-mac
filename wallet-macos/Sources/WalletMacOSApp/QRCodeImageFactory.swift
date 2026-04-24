import AppKit
import CoreImage

struct QRCodeImageFactory {
    private let context = CIContext()

    func image(
        for string: String,
        dimension: CGFloat = 220
    ) -> NSImage? {
        guard
            let data = string.data(using: .utf8),
            let generator = CIFilter(name: "CIQRCodeGenerator")
        else {
            return nil
        }

        generator.setValue(data, forKey: "inputMessage")
        generator.setValue("M", forKey: "inputCorrectionLevel")

        guard let output = generator.outputImage else {
            return nil
        }

        let colored = output.applyingFilter(
            "CIFalseColor",
            parameters: [
                "inputColor0": CIColor(red: 0, green: 0, blue: 0),
                "inputColor1": CIColor(red: 1, green: 1, blue: 1),
            ]
        )

        let scaleX = dimension / colored.extent.width
        let scaleY = dimension / colored.extent.height
        let transformed = colored.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: dimension, height: dimension))
    }
}
