import AppKit
import Foundation

// MacBook geometry with the original Steam.app icon composited without recoloring.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func draw(size: Int, to destination: URL) throws {
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: image)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    cg.translateBy(x: 0, y: 1024); cg.scaleBy(x: 1, y: -1)
    let background = CGPath(roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896), cornerWidth: 200, cornerHeight: 200, transform: nil)
    cg.saveGState(); cg.addPath(background); cg.clip()
    let colors = [CGColor(srgbRed: 12/255, green: 30/255, blue: 59/255, alpha: 1), CGColor(srgbRed: 23/255, green: 108/255, blue: 151/255, alpha: 1)]
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 64), end: CGPoint(x: 512, y: 960), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]); cg.restoreGState()
    func roundedRect(_ rect: CGRect, _ radius: CGFloat, _ color: CGColor) {
        cg.setFillColor(color)
        cg.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)); cg.fillPath()
    }
    let silver = CGColor(srgbRed: 190/255, green: 199/255, blue: 209/255, alpha: 1)
    let bezel = CGColor(srgbRed: 14/255, green: 39/255, blue: 68/255, alpha: 1)
    roundedRect(CGRect(x: 140, y: 158, width: 744, height: 638), 32, silver)
    roundedRect(CGRect(x: 148, y: 166, width: 728, height: 622), 25, bezel)
    cg.saveGState()
    cg.addPath(CGPath(roundedRect: CGRect(x: 164, y: 184, width: 696, height: 578), cornerWidth: 10, cornerHeight: 10, transform: nil)); cg.clip()
    cg.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 184), end: CGPoint(x: 512, y: 762), options: [])
    cg.restoreGState()
    // Composite the native Steam artwork unchanged, including its circular gradient.
    let steamURL = root.appendingPathComponent("Assets/SteamOriginal.png")
    let steam = NSImage(contentsOf: steamURL)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    cg.saveGState()
    cg.translateBy(x: 212, y: 773); cg.scaleBy(x: 1, y: -1)
    cg.interpolationQuality = .high
    cg.draw(steam, in: CGRect(x: 0, y: 0, width: 600, height: 600))
    cg.restoreGState()
    cg.setFillColor(CGColor(srgbRed: 0.36, green: 0.41, blue: 0.47, alpha: 1))
    cg.fillEllipse(in: CGRect(x: 508, y: 171, width: 8, height: 8))
    // Front-facing MacBook chassis with the recognizable central opening lip.
    let base = CGMutablePath()
    base.move(to: CGPoint(x: 110, y: 790)); base.addLine(to: CGPoint(x: 914, y: 790))
    base.addLine(to: CGPoint(x: 914, y: 808))
    base.addCurve(to: CGPoint(x: 860, y: 844), control1: CGPoint(x: 908, y: 832), control2: CGPoint(x: 884, y: 844))
    base.addLine(to: CGPoint(x: 164, y: 844))
    base.addCurve(to: CGPoint(x: 110, y: 808), control1: CGPoint(x: 140, y: 844), control2: CGPoint(x: 116, y: 832))
    base.closeSubpath()
    cg.saveGState(); cg.addPath(base); cg.clip()
    let metalGradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
        CGColor(srgbRed: 226/255, green: 231/255, blue: 236/255, alpha: 1), silver,
        CGColor(srgbRed: 133/255, green: 145/255, blue: 159/255, alpha: 1)
    ] as CFArray, locations: [0, 0.45, 1])!
    cg.drawLinearGradient(metalGradient, start: CGPoint(x: 512, y: 790), end: CGPoint(x: 512, y: 844), options: [])
    cg.restoreGState()
    roundedRect(CGRect(x: 446, y: 784, width: 132, height: 23), 10,
        CGColor(srgbRed: 134/255, green: 145/255, blue: 157/255, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    try image.representation(using: .png, properties: [:])!.write(to: destination)
}
let iconset = root.appendingPathComponent("Assets/Portlane.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try draw(size: size, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try draw(size: size * 2, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try draw(size: 1024, to: root.appendingPathComponent("Assets/PortlaneIcon.png"))
try draw(size: 256, to: root.appendingPathComponent("Sources/MacGamingUncleApp/Resources/portlane-mark.png"))
