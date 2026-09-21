import AppKit
import AVFoundation
import CoreVideo

let W = 1080, H = 1920, fps: Int32 = 30
let scriptDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let projectDirectory = scriptDirectory.deletingLastPathComponent().deletingLastPathComponent()
let root = projectDirectory.appendingPathComponent("Stocked/Assets .xcassets").path
let output = ProcessInfo.processInfo.environment["STOCKED_PROMO_OUTPUT"]
    ?? scriptDirectory.appendingPathComponent("Stocked-Promo-Features-1080x1920.mp4").path

struct Scene {
    let eyebrow: String
    let title: String
    let body: String
    let image: String
    let accent: NSColor
}

let scenes = [
    Scene(eyebrow: "MEET STOCKED", title: "Your kitchen,\nfinally organized.", body: "Inventory, recipes, shopping, and meal planning—working together.", image: "home_kitchen_still_life.imageset/home_kitchen_still_life.png", accent: NSColor(calibratedRed: 0.67, green: 0.35, blue: 0.05, alpha: 1)),
    Scene(eyebrow: "SMART INVENTORY", title: "Know what you have.", body: "See your fridge, freezer, pantry, produce, and leftovers in one beautiful place.", image: "inventory_refrigerator_hero.imageset/inventory_refrigerator_hero.png", accent: NSColor(calibratedRed: 0.28, green: 0.45, blue: 0.23, alpha: 1)),
    Scene(eyebrow: "WASTE LESS", title: "Use it before\nyou lose it.", body: "Spot expiring food and low-stock staples before they become a problem.", image: "inventory_expiring_reference.imageset/inventory_expiring_reference.png", accent: NSColor(calibratedRed: 0.76, green: 0.38, blue: 0.08, alpha: 1)),
    Scene(eyebrow: "COOK WITH WHAT YOU HAVE", title: "Dinner starts\nwith your kitchen.", body: "Find recipes you can make now—or see the one ingredient you’re missing.", image: "cook_now_hero.imageset/cook_now_hero.png", accent: NSColor(calibratedRed: 0.55, green: 0.25, blue: 0.12, alpha: 1)),
    Scene(eyebrow: "RECIPE DISCOVERY", title: "Find your next\nfavorite recipe.", body: "Explore by cuisine, mood, dietary needs, meal type, and ingredients on hand.", image: "recipes_hero.imageset/recipes_hero.png", accent: NSColor(calibratedRed: 0.62, green: 0.28, blue: 0.12, alpha: 1)),
    Scene(eyebrow: "SMART SHOPPING", title: "A grocery list\nthat thinks ahead.", body: "Turn missing ingredients and running-low items into an organized shopping plan.", image: "home_grocery_bag.imageset/home_grocery_bag.png", accent: NSColor(calibratedRed: 0.18, green: 0.43, blue: 0.31, alpha: 1)),
    Scene(eyebrow: "ONE HOUSEHOLD", title: "In sync,\nwherever you cook.", body: "Keep your kitchen current across iPhone, Mac, Apple Watch, widgets, and your household.", image: "home_widget_planning.imageset/home_widget_planning.png", accent: NSColor(calibratedRed: 0.25, green: 0.32, blue: 0.55, alpha: 1)),
    Scene(eyebrow: "STOCKED", title: "Buy smarter.\nCook easier.\nWaste less.", body: "Your whole kitchen, in one place.", image: "AppIcon.appiconset/AppIcon-1024px.png", accent: NSColor(calibratedRed: 0.73, green: 0.40, blue: 0.08, alpha: 1))
]

let sceneSeconds = 4.0
let duration = Double(scenes.count) * sceneSeconds
let fm = FileManager.default
try? fm.removeItem(atPath: output)

let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: output), fileType: .mp4)
let settings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: W,
    AVVideoHeightKey: H,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 10_000_000,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
    ]
]
let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
input.expectsMediaDataInRealTime = false
let attrs: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: W,
    kCVPixelBufferHeightKey as String: H
]
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
writer.add(input)
guard writer.startWriting() else { fatalError("Unable to start: \(writer.error?.localizedDescription ?? "unknown")") }
writer.startSession(atSourceTime: .zero)

func ease(_ x: CGFloat) -> CGFloat { let y = max(0, min(1, x)); return y * y * (3 - 2 * y) }

func paragraph(_ text: String, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left, lineSpacing: CGFloat = 5) -> NSAttributedString {
    let p = NSMutableParagraphStyle(); p.alignment = alignment; p.lineSpacing = lineSpacing
    return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
}

func drawImage(_ image: NSImage, in rect: NSRect, context: CGContext) {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
    let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
    let scale = min(rect.width / iw, rect.height / ih)
    let size = NSSize(width: iw * scale, height: ih * scale)
    let dst = NSRect(x: rect.midX - size.width/2, y: rect.midY - size.height/2, width: size.width, height: size.height)
    context.saveGState(); context.translateBy(x: 0, y: CGFloat(H)); context.scaleBy(x: 1, y: -1)
    context.draw(cg, in: NSRect(x: dst.minX, y: CGFloat(H) - dst.maxY, width: dst.width, height: dst.height))
    context.restoreGState()
}

func render(scene: Scene, local: CGFloat, buffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = CVPixelBufferGetBaseAddress(buffer)!
    let cs = CGColorSpaceCreateDeviceRGB()
    let cg = CGContext(data: base, width: W, height: H, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let ns = NSGraphicsContext(cgContext: cg, flipped: false)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns

    let warm = NSColor(calibratedRed: 0.965, green: 0.90, blue: 0.79, alpha: 1)
    cg.setFillColor(warm.cgColor); cg.fill(CGRect(x: 0, y: 0, width: W, height: H))
    let fade = min(ease(local / 0.45), ease((CGFloat(sceneSeconds) - local) / 0.45))
    cg.setAlpha(fade)

    let image = NSImage(contentsOfFile: root + "/" + scene.image)!
    let isIcon = scene.image.contains("AppIcon")
    let imageBox = isIcon ? NSRect(x: 290, y: 850, width: 500, height: 500) : NSRect(x: 70, y: 690, width: 940, height: 820)
    let float = 14 * sin(local * .pi / CGFloat(sceneSeconds))
    let scaled = imageBox.insetBy(dx: -18 * local/CGFloat(sceneSeconds), dy: -18 * local/CGFloat(sceneSeconds)).offsetBy(dx: 0, dy: float)

    let shadowPath = CGPath(roundedRect: scaled.insetBy(dx: 45, dy: 45), cornerWidth: 64, cornerHeight: 64, transform: nil)
    cg.saveGState(); cg.setShadow(offset: CGSize(width: 0, height: -24), blur: 45, color: NSColor.black.withAlphaComponent(0.15).cgColor); cg.setFillColor(NSColor.white.withAlphaComponent(0.17).cgColor); cg.addPath(shadowPath); cg.fillPath(); cg.restoreGState()
    drawImage(image, in: scaled, context: cg)

    let x: CGFloat = 82
    paragraph(scene.eyebrow, font: .systemFont(ofSize: 34, weight: .semibold), color: scene.accent).draw(in: NSRect(x: x, y: 1690, width: 916, height: 52))
    paragraph(scene.title, font: .systemFont(ofSize: isIcon ? 90 : 84, weight: .bold), color: NSColor(calibratedWhite: 0.075, alpha: 1), lineSpacing: -1).draw(in: NSRect(x: x, y: isIcon ? 470 : 1450, width: 916, height: isIcon ? 330 : 250))
    paragraph(scene.body, font: .systemFont(ofSize: 39, weight: .regular), color: NSColor(calibratedWhite: 0.24, alpha: 1), lineSpacing: 9).draw(in: NSRect(x: x, y: isIcon ? 300 : 1300, width: 890, height: 150))

    let barY: CGFloat = 86
    for i in 0..<scenes.count {
        let bx = CGFloat(82 + i * 115)
        let active = i == scenes.firstIndex(where: { $0.title == scene.title })
        cg.setFillColor((active ? scene.accent : NSColor.black.withAlphaComponent(0.13)).cgColor)
        cg.fill(CGRect(x: bx, y: barY, width: active ? 86 : 54, height: 8))
    }
    NSGraphicsContext.restoreGraphicsState()
}

let totalFrames = Int(duration * Double(fps))
for frame in 0..<totalFrames {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    guard let buffer = pb else { fatalError("Pixel buffer allocation failed") }
    let seconds = Double(frame) / Double(fps)
    let index = min(scenes.count - 1, Int(seconds / sceneSeconds))
    let local = CGFloat(seconds - Double(index) * sceneSeconds)
    render(scene: scenes[index], local: local, buffer: buffer)
    let time = CMTime(value: CMTimeValue(frame), timescale: fps)
    if !adaptor.append(buffer, withPresentationTime: time) { fatalError("Append failed: \(writer.error?.localizedDescription ?? "unknown")") }
    if frame % 120 == 0 { print("Rendered \(frame)/\(totalFrames)") }
}

input.markAsFinished()
let semaphore = DispatchSemaphore(value: 0)
writer.finishWriting { semaphore.signal() }
semaphore.wait()
guard writer.status == .completed else { fatalError("Export failed: \(writer.error?.localizedDescription ?? "unknown")") }
print(output)
