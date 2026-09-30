import UIKit
import ImageIO
import UniformTypeIdentifiers

@main
struct CoverThumbnailChecks {
    @MainActor
    static func main() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: file) }
        func writeImage(width: Int, height: Int) throws {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(UIColor.systemBlue.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            precondition(CGImageDestinationFinalize(destination))
        }
        try writeImage(width: 4096, height: 2160)
        let cache = CoverThumbnailCache.shared
        let first = await cache.load(path: file.path, bookmark: nil, maxPixels: 512)!
        let decoded = first.cgImage!
        precondition(decoded.width <= 512 && decoded.height <= 512, "Decode only thumbnail pixels")
        let second = await cache.load(path: file.path, bookmark: nil, maxPixels: 512)!
        precondition(first === second, "Repeated requests reuse the decoded thumbnail")
        try writeImage(width: 128, height: 128)
        let changed = await cache.load(path: file.path, bookmark: nil, maxPixels: 512)!
        precondition(changed !== first && changed.cgImage!.width == 128, "Changed file invalidates cached thumbnail")
        let missing = await cache.load(path: file.path + ".missing", bookmark: nil, maxPixels: 512)
        precondition(missing == nil)
        print("PASS: 4096x2160 cover -> \(decoded.width)x\(decoded.height), \(decoded.bytesPerRow * decoded.height) decoded bytes; cache reuse and invalidation")
    }
}
