// Generates the Kelvin app icon: a dark macOS squircle with a glowing blackbody
// "temperature orb" — the Kelvin scale (amber → daylight → blue) made into a lit sphere,
// with a warm bloom. Renders a 1024 master, downsamples to the iconset, and builds .icns.
//
//   swift scripts/make-icon.swift <out-dir>
//
// Produces <out-dir>/Kelvin.iconset and <out-dir>/Kelvin.icns.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [
        Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255,
        Double(hex & 0xFF) / 255, a])!
}

func renderMaster(_ S: Double) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let c = CGPoint(x: S / 2, y: S / 2)

    // Squircle background with a dark radial gradient for depth.
    let inset = S * 0.098
    let rect = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
    let squircle = CGPath(roundedRect: rect, cornerWidth: S * 0.18, cornerHeight: S * 0.18, transform: nil)
    ctx.saveGState(); ctx.addPath(squircle); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x272C35), rgb(0x14161A)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(bg, startCenter: CGPoint(x: c.x, y: S * 0.60), startRadius: 0,
                           endCenter: c, endRadius: S * 0.72, options: [.drawsAfterEndLocation])

    // Warm bloom behind the orb — the blackbody glow.
    let bloom = CGGradient(colorsSpace: cs, colors: [rgb(0xFF9A55, 0.55), rgb(0xFF7A3C, 0.12), rgb(0xFF7A3C, 0)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawRadialGradient(bloom, startCenter: c, startRadius: 0, endCenter: c, endRadius: S * 0.40, options: [])
    ctx.restoreGState()

    // The orb: a circle carrying the Kelvin gradient (amber → daylight → cool), lit as a sphere.
    let r = S * 0.245
    let orb = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)

    ctx.saveGState(); ctx.addEllipse(in: orb); ctx.clip()
    // Saturated Kelvin scale so the temperature reads unmistakably; a narrow daylight core.
    let kelvin = CGGradient(colorsSpace: cs,
                            colors: [rgb(0xFF7A2E), rgb(0xFF9A4E), rgb(0xF6ECD6), rgb(0x5AA0FF), rgb(0x3D7EE0)] as CFArray,
                            locations: [0, 0.28, 0.5, 0.72, 1])!
    ctx.drawLinearGradient(kelvin, start: CGPoint(x: c.x - r, y: c.y), end: CGPoint(x: c.x + r, y: c.y), options: [])
    // Sphere modelling: light from upper-left, shadow lower-right — gentle, lets colour show.
    let model = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.16), rgb(0x000000, 0), rgb(0x05070A, 0.45)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawRadialGradient(model, startCenter: CGPoint(x: c.x - r * 0.35, y: c.y + r * 0.45), startRadius: 0,
                           endCenter: c, endRadius: r * 1.2, options: [])
    // Compact specular glint (kept well inside the limb so it never reads as a ring).
    let spec = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.55), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(spec, startCenter: CGPoint(x: c.x - r * 0.34, y: c.y + r * 0.46), startRadius: 0,
                           endCenter: CGPoint(x: c.x - r * 0.34, y: c.y + r * 0.46), endRadius: r * 0.34, options: [])
    ctx.restoreGState()

    return ctx.makeImage()!
}

func downsample(_ master: CGImage, _ size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: outDir).appendingPathComponent("Kelvin.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let master = renderMaster(1024)
let specs: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (size, name) in specs {
    writePNG(downsample(master, size), iconset.appendingPathComponent(name))
}
// Also drop a standalone 1024 preview.
writePNG(master, URL(fileURLWithPath: outDir).appendingPathComponent("Kelvin-1024.png"))
print("Wrote \(iconset.path)")
