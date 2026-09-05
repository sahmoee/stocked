import Foundation
import ImageIO
import CoreGraphics

/// Read-only guard against missing, oversized, opaque or blank decorative cutouts.
@main
struct KitchenArtworkAudit {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
        let names = ["inventory_expiring_reference", "inventory_low_reference", "inventory_add_reference",
                     "kitchen_protein_reference", "kitchen_leftovers_reference"]
        var checks = 0
        for name in names {
            let directory = root.appendingPathComponent("Stocked/Assets .xcassets/\(name).imageset")
            let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("Contents.json"))) as? [String: Any]
            let files = catalog?["images"] as? [[String: Any]]
            guard files?.first?["filename"] as? String == "\(name).png" else { fatalError("Invalid catalog: \(name)") }
            checks += 1
            let url = directory.appendingPathComponent("\(name).png")
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("Unreadable image: \(name)") }
            guard (512...2048).contains(picture.width), (512...2048).contains(picture.height) else { fatalError("Unexpected dimensions: \(name)") }
            checks += 1
            guard [.first, .last, .premultipliedFirst, .premultipliedLast].contains(picture.alphaInfo) else { fatalError("Opaque image, possibly baked checkerboard: \(name)") }
            checks += 1
            let size = 128
            var rgba = [UInt8](repeating: 0, count: size * size * 4)
            rgba.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(data: bytes.baseAddress, width: size, height: size, bitsPerComponent: 8,
                    bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { fatalError("Cannot inspect image") }
                context.draw(picture, in: CGRect(x: 0, y: 0, width: size, height: size))
            }
            let alphas = stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
            let transparent = alphas.filter { $0 < 8 }.count
            let solid = alphas.filter { $0 > 240 }.count
            guard transparent > alphas.count / 20, solid > alphas.count / 10 else { fatalError("No meaningful transparent cutout: \(name)") }
            checks += 1
            print("\(name): \(picture.width)x\(picture.height), \(transparent * 100 / alphas.count)% clear, \(solid * 100 / alphas.count)% solid — passed")
        }
        print("Kitchen artwork: \(checks) checks passed; pixel identity and on-device contrast require visual QA.")
    }
}
