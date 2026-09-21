import AppKit
import CoreImage
import Vision

guard CommandLine.arguments.count == 3 else {
    fputs("usage: remove_foreground_background input.png output.png\n", stderr)
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CIImage(contentsOf: inputURL) else {
    fputs("could not load input image\n", stderr)
    exit(3)
}

let request = VNGenerateForegroundInstanceMaskRequest()
let handler = VNImageRequestHandler(ciImage: source)
try handler.perform([request])
guard let observation = request.results?.first else {
    fputs("Vision did not find a foreground subject\n", stderr)
    exit(4)
}

let maskBuffer = try observation.generateScaledMaskForImage(
    forInstances: observation.allInstances,
    from: handler
)
let mask = CIImage(cvPixelBuffer: maskBuffer)
let transparent = CIImage(color: .clear).cropped(to: source.extent)
guard let composited = CIFilter(
    name: "CIBlendWithMask",
    parameters: [
        kCIInputImageKey: source,
        kCIInputBackgroundImageKey: transparent,
        kCIInputMaskImageKey: mask
    ]
)?.outputImage else {
    fputs("could not composite foreground mask\n", stderr)
    exit(5)
}

let context = CIContext(options: [.useSoftwareRenderer: false])
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
try context.writePNGRepresentation(
    of: composited,
    to: outputURL,
    format: .RGBA8,
    colorSpace: colorSpace
)
