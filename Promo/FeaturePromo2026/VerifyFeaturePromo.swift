import AppKit
import AVFoundation

let scriptDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let input = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STOCKED_PROMO_OUTPUT"]
    ?? scriptDirectory.appendingPathComponent("Stocked-Promo-Features-1080x1920.mp4").path)
let output = scriptDirectory.appendingPathComponent("verification-contact-sheet.png").path
let asset = AVURLAsset(url: input)
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.maximumSize = CGSize(width: 270, height: 480)
let times = stride(from: 2.0, through: 30.0, by: 4.0).map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 600)) }
let sheet = NSImage(size: NSSize(width: 1080, height: 960))
sheet.lockFocus()
NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 1080, height: 960).fill()
for (index, value) in times.enumerated() {
    let image = try generator.copyCGImage(at: value.timeValue, actualTime: nil)
    let x = CGFloat(index % 4) * 270
    let y = CGFloat(1 - index / 4) * 480
    NSGraphicsContext.current?.cgContext.draw(image, in: CGRect(x: x, y: y, width: 270, height: 480))
}
sheet.unlockFocus()
guard let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { fatalError("Unable to encode sheet") }
try png.write(to: URL(fileURLWithPath: output))
print("duration=\(asset.duration.seconds)")
print(output)
