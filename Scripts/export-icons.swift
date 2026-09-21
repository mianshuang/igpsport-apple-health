import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
for name in ["Light", "Dark", "Tinted"] {
    let sourceURL = URL(fileURLWithPath: "/tmp/AppIcon-\(name).svg.png")
    guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw NSError(domain: "IconRender", code: 1) }
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    let output = URL(fileURLWithPath: "FITHealth/Assets.xcassets/AppIcon.appiconset/AppIcon-\(name).png")
    guard let rendered = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw NSError(domain: "IconRender", code: 2) }
    CGImageDestinationAddImage(destination, rendered, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "IconRender", code: 3) }
}
