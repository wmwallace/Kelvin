#!/usr/bin/env swift
// Generates the app icon — a lit instrument for measuring light.
//
// The mark is the colour-temperature scale bent into a gauge: an open ring that sweeps
// amber (~2700K) through neutral daylight at twelve o'clock to blue (~9000K), with a
// single white-hot point of light held at its centre. One idea: a light, measured.
//
// Deliberately no letterforms and no wordmark — the product name is not final, so the
// icon must survive a rename. Deliberately no fine detail: at 16px the whole thing has
// to survive as a coloured horseshoe around a bright dot, and nothing smaller than the
// ring stroke is allowed to carry meaning.
//
//   scripts/make-icon.swift [preview-dir]
//
// One command regenerates everything the app ships: the .icns that package-app.sh drops
// into the bundle, and the base64 the app installs as its Dock icon at launch. Pass a
// directory to also get the ten loose PNGs and a 1024 preview for eyeballing.
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let cs = CGColorSpace(name: CGColorSpace.sRGB)!

// Paths are derived from this file's own location so the script works from any cwd.
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let package = repoRoot.appendingPathComponent("Integrations/KelvinPerceptionMLX")
let icnsURL = package.appendingPathComponent("AppIcon/Kelvin.icns")
let embedURL = package.appendingPathComponent("Sources/KelvinApp/AppIconData.swift")
let previewDir = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : nil

func rgb(_ hex: UInt32, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [
        Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255,
        Double(hex & 0xFF) / 255, a])!
}

func bitmap(_ size: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    return ctx
}

// MARK: - Geometry

// Apple's macOS icon grid: the tile is 824/1024 of the canvas, centred, leaving the
// margin the system expects for shadow and alignment with every other Dock icon.
let tileFraction = 824.0 / 1024.0

/// A superellipse — the continuous-curvature "squircle" macOS actually uses. A plain
/// rounded rect reads subtly wrong next to system icons at 512px and up.
func squirclePath(side: Double, center: CGPoint, exponent n: Double = 5) -> CGPath {
    let a = side / 2, p = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = center.x + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = center.y + a * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

// The Kelvin scale, saturated a little past the UI's rail at both ends: tiny renders eat
// chroma, and an icon that has gone grey at 16px has lost the only thing it is saying.
let ramp: [(Double, UInt32)] = [
    (0.00, 0xFF7A1E),   // ~2400K, ember
    (0.24, 0xFF9A55),   // ~2900K, the app's warm anchor
    (0.50, 0xF7F0E1),   // ~5500K, daylight
    (0.76, 0x6FACFF),   // ~8600K, the app's cool anchor
    (1.00, 0x2F72E8),   // ~10000K, deep blue
]

func rampColor(_ u: Double) -> CGColor {
    let u = min(max(u, 0), 1)
    for i in 1..<ramp.count where u <= ramp[i].0 {
        let (u0, c0) = ramp[i - 1], (u1, c1) = ramp[i]
        let f = (u - u0) / (u1 - u0)
        func ch(_ shift: UInt32) -> Double {
            let a = Double((c0 >> shift) & 0xFF), b = Double((c1 >> shift) & 0xFF)
            return (a + (b - a) * f) / 255
        }
        return CGColor(colorSpace: cs, components: [ch(16), ch(8), ch(0), 1])!
    }
    return rgb(ramp[ramp.count - 1].1)
}

// MARK: - The mark

// Gauge geometry, in canvas fractions. The ring is open at the bottom so the silhouette
// is a horseshoe, not a circle — a closed multicoloured ring on a Mac reads as a spinner.
let gaugeOuter = 0.305          // outer radius
let gaugeStroke = 0.112         // ring thickness — 1.8px at 16px, the legibility floor
let gapHalfAngle = 44.0         // half the opening at six o'clock
let coreRadius = 0.042          // the point of light at the centre

/// Arc + centre light on transparent ground, so it can be blurred into its own bloom.
func drawMark(_ ctx: CGContext, _ S: Double) {
    let c = CGPoint(x: S / 2, y: S * 0.487)   // nudged down: the open bottom lifts the mass
    let r = S * (gaugeOuter - gaugeStroke / 2)
    let w = S * gaugeStroke

    // Sweep the scale around the arc by stroking many overlapping round-capped segments:
    // one gradient, laid along a curve, with no seams and free rounded ends.
    let start = 312.0, sweep = 360.0 - 2 * gapHalfAngle   // 276°, amber left → blue right
    let segments = 480
    ctx.setLineCap(.round)
    ctx.setLineWidth(w)
    for i in 0..<segments {
        let f0 = Double(i) / Double(segments), f1 = Double(i + 1) / Double(segments)
        let a0 = (start + f0 * sweep) * .pi / 180, a1 = (start + f1 * sweep) * .pi / 180
        // u = 0 at the left-hand (amber) end, 1 at the right-hand (blue) end.
        ctx.setStrokeColor(rampColor(1 - (f0 + f1) / 2))
        ctx.beginPath()
        ctx.addArc(center: c, radius: r, startAngle: a0, endAngle: a1, clockwise: false)
        ctx.strokePath()
    }

    // The source being measured: a warm-white point, hot in the middle, at the pivot.
    // Dropped entirely below 24px, where it is one grey pixel that fills the ring's hole
    // and costs more legibility than it buys meaning — at that size the open C is the
    // whole idea, and it wants a clean dark centre to read against.
    guard S >= 24 else { return }
    let core = CGGradient(colorsSpace: cs,
                          colors: [rgb(0xFFFFFF), rgb(0xFFF4E2), rgb(0xFFD9A8, 0.85), rgb(0xFFB56B, 0)] as CFArray,
                          locations: [0, 0.42, 0.72, 1])!
    ctx.drawRadialGradient(core, startCenter: c, startRadius: 0,
                           endCenter: c, endRadius: S * coreRadius * 1.3, options: [])
}

func blurred(_ image: CGImage, radius: Double, _ S: Double) -> CGImage {
    let ci = CIImage(cgImage: image)
    let blur = CIFilter(name: "CIGaussianBlur")!
    blur.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
    blur.setValue(radius, forKey: kCIInputRadiusKey)
    let out = blur.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: S, height: S))
    return CIContext(options: [.workingColorSpace: cs]).createCGImage(out, from: out.extent)!
}

// MARK: - Master

func renderMaster(_ S: Double) -> CGImage {
    let ctx = bitmap(Int(S))
    let center = CGPoint(x: S / 2, y: S / 2)
    let tile = S * tileFraction
    let squircle = squirclePath(side: tile, center: center)

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // Ground: a darkroom, not a black hole. Lifted and slightly cool at the top, sinking
    // to near-black at the bottom, so the tile has a light direction of its own.
    let bg = CGGradient(colorsSpace: cs,
                        colors: [rgb(0x2A3240), rgb(0x1A1F28), rgb(0x0D1014)] as CFArray,
                        locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: S / 2, y: S), end: CGPoint(x: S / 2, y: 0),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // Ambient wash from the two ends of the scale — warm spills left, cool spills right.
    // Barely there at full size; at 16px it is the difference between a tile with air in
    // it and a flat grey square.
    let warmWash = CGGradient(colorsSpace: cs, colors: [rgb(0xFF8A3A, 0.20), rgb(0xFF8A3A, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(warmWash, startCenter: CGPoint(x: S * 0.20, y: S * 0.30), startRadius: 0,
                           endCenter: CGPoint(x: S * 0.20, y: S * 0.30), endRadius: S * 0.52, options: [])
    let coolWash = CGGradient(colorsSpace: cs, colors: [rgb(0x4E8CFF, 0.20), rgb(0x4E8CFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(coolWash, startCenter: CGPoint(x: S * 0.82, y: S * 0.30), startRadius: 0,
                           endCenter: CGPoint(x: S * 0.82, y: S * 0.30), endRadius: S * 0.52, options: [])

    // Mark, drawn once for its bloom and once for itself.
    let markCtx = bitmap(Int(S))
    drawMark(markCtx, S)
    let mark = markCtx.makeImage()!
    let rect = CGRect(x: 0, y: 0, width: S, height: S)

    // Restraint here is what makes the icon legible small: every point of bloom leaks into
    // the ring's opening and its hole, and once those fill in the horseshoe is a blob.
    ctx.setAlpha(0.42)
    ctx.draw(blurred(mark, radius: S * 0.018, S), in: rect)   // tight halo: emissive, not foggy
    ctx.setAlpha(0.16)
    ctx.draw(blurred(mark, radius: S * 0.055, S), in: rect)   // wide bloom lighting the tile
    ctx.setAlpha(1)
    ctx.draw(mark, in: rect)

    ctx.restoreGState()

    // Glass edge: a bright hairline along the top of the tile fading out by the equator,
    // and a dark one along the bottom. This is the whole depth budget.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    ctx.addPath(squircle)
    ctx.setLineWidth(S * 0.007)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let edge = CGGradient(colorsSpace: cs,
                          colors: [rgb(0xFFFFFF, 0.34), rgb(0xFFFFFF, 0.03), rgb(0x000000, 0.22)] as CFArray,
                          locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(edge, start: CGPoint(x: S / 2, y: S), end: CGPoint(x: S / 2, y: 0), options: [])
    ctx.restoreGState()

    return ctx.makeImage()!
}

// MARK: - Output

func downsample(_ master: CGImage, _ size: Int) -> CGImage {
    let ctx = bitmap(size)
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

func pngData(_ image: CGImage) -> Data {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return Data() }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

func writePNG(_ image: CGImage, _ url: URL) {
    try? pngData(image).write(to: url)
}

let fm = FileManager.default
let master = renderMaster(1024)

// Small sizes are rendered at their native resolution rather than shrunk from the master.
// The ring stroke lands on ~2 pixels either way, but rendering it natively keeps its edges
// crisp instead of smearing them across three — which is the whole ballgame at 16px.
let specs: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
var rendered: [Int: CGImage] = [1024: master]
func image(_ size: Int) -> CGImage {
    if let cached = rendered[size] { return cached }
    let img = size <= 128 ? renderMaster(Double(size)) : downsample(master, size)
    rendered[size] = img
    return img
}

// Build the iconset in a scratch directory: the repo keeps the .icns, not ten PNGs.
let staging = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("icon-\(UUID().uuidString)")
let iconset = staging.appendingPathComponent("Kelvin.iconset")
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for (size, name) in specs { writePNG(image(size), iconset.appendingPathComponent(name)) }

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icnsURL.path]
try! fm.createDirectory(at: icnsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try! iconutil.run()
iconutil.waitUntilExit()
print("✓ \(icnsURL.path)")

// The Dock icon is embedded as bytes rather than read from the bundle, so regenerating it
// means rewriting that source file. 256px is what the Dock and the ⌘-Tab switcher ask for
// at 2x; a 512 would quadruple the size of a file that is already only there to be parsed.
let base64 = pngData(image(256)).base64EncodedString()
let source = """
import Foundation

// The app icon embedded as bytes so the Dock icon shows even under `swift run`
// (no Bundle.module lookup, which fatal-errors in a hand-assembled .app).
//
// Generated — do not edit by hand. Run `scripts/make-icon.swift` to regenerate.
enum AppIconData {
    static let base64 = "\(base64)"
}

"""
try! source.write(to: embedURL, atomically: true, encoding: .utf8)
print("✓ \(embedURL.path)")

if let previewDir {
    try? fm.createDirectory(at: previewDir, withIntermediateDirectories: true)
    for (size, name) in specs { writePNG(image(size), previewDir.appendingPathComponent(name)) }
    writePNG(master, previewDir.appendingPathComponent("icon-1024.png"))
    print("✓ \(previewDir.path)")
}
try? fm.removeItem(at: staging)
