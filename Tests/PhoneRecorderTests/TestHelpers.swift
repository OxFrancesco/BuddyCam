import CoreGraphics
import Foundation
import ImageIO

// Generates a solid-color JPEG of the given size for ingest tests.
func makeTestJPEG(size: Int = 160) throws -> Data {
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    for i in stride(from: 0, to: pixels.count, by: 4) {
        pixels[i] = 200; pixels[i + 1] = 80; pixels[i + 2] = 70; pixels[i + 3] = 255
    }
    let data = Data(pixels) as CFData
    let provider = CGDataProvider(data: data)!
    let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}
