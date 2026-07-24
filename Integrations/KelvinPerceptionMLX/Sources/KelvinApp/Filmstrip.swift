import SwiftUI
import CoreImage
import ImageIO
import AppKit
import KelvinCore

/// Browsing the folder you opened a photo from — the thing every photo app has and Kelvin didn't:
/// somewhere to see the rest of the shoot, and a way back to a frame you already worked on.
enum PhotoBrowser {

    /// Image files sitting alongside `url`, in a stable order. Uses the same extension list the
    /// batch path does, so what you can browse is what Kelvin can actually edit.
    static func siblings(of url: URL) -> [URL] {
        let dir = url.deletingLastPathComponent()
        return (try? BatchApply.imageFiles(in: dir))?.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } ?? [url]
    }

    /// A small thumbnail for the strip. Decoding a 60 MP RAW per thumbnail would be absurd, so this
    /// asks ImageIO for an embedded/downsampled one — fast, and it never touches the edit pipeline.
    static func thumbnail(for url: URL, maxPixel: Int = 160) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}

/// Everything needed to put a photo back exactly as you left it, without re-running the model.
/// Cached per photo so switching away and back is instant and lossless.
struct PhotoSession {
    let url: URL
    let imageId: String
    let fullResCI: CIImage
    let proxyCI: CIImage
    let originalPreviewImage: NSImage?
    let perception: Perception?
    let candidates: [CandidateViewModel]
    let proxyMaskBitmaps: [String: CIImage]
    let subjectLuma: Double?
    let skyLuma: Double?
    let healSpots: [HealSpot]
    let detectedSpotCount: Int

    // The edit itself.
    var selectedCandidateId: String?
    var edit: GlobalAdjustments
    var editBaseline: GlobalAdjustments
    var baseMasks: [Mask]
    var maskEnabled: [String: Bool]
    var maskStrength: [String: Double]
    var userMasks: [UserMaskVM]
    var straighten: Double
    var hsl: [String: HSLAdjustment]
    var removeDust: Bool

    /// Whether the user actually changed anything from the candidate Kelvin generated — drives the
    /// "edited" dot in the strip.
    var isEdited: Bool {
        edit != editBaseline || !userMasks.isEmpty || straighten != 0 || !hsl.isEmpty || removeDust
    }
}

/// A horizontal strip of the folder's photos under the preview, Lightroom-style — bottom placement
/// keeps it clear of the edit panel.
struct FilmstripView: View {
    let photos: [URL]
    let current: URL?
    let editedURLs: Set<URL>
    let thumbnail: (URL) -> NSImage?
    let onSelect: (URL) -> Void
    var onDismiss: (URL) -> Void = { _ in }
    @State private var hovered: URL?

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(photos, id: \.self) { url in
                            cell(url).id(url)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .onChange(of: current) { url in
                    guard let url else { return }
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(url, anchor: .center) }
                }
            }
        }
        .background(Theme.surface.opacity(0.6))
    }

    private func cell(_ url: URL) -> some View {
        let isCurrent = url == current
        return Button(action: { onSelect(url) }) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = thumbnail(url) {
                        Image(nsImage: img).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Theme.surface2)
                    }
                }
                .frame(width: 78, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isCurrent ? Theme.glow : Theme.hairline,
                                lineWidth: isCurrent ? 2 : 1)
                )
                // A dot marks frames you've already worked on, so a pass through a shoot is legible.
                if editedURLs.contains(url) && hovered != url {
                    Circle().fill(Theme.glow)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Theme.base, lineWidth: 1))
                        .padding(4)
                }
                // Hovering reveals a way to drop the frame from the working set.
                if hovered == url {
                    Button(action: { onDismiss(url) }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white, Color.black.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                    .padding(3)
                    .help("Remove from this session")
                }
            }
            .opacity(isCurrent ? 1 : 0.72)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? url : (hovered == url ? nil : hovered) }
        .help(url.lastPathComponent)
    }
}

/// Chips that wrap onto as many lines as they need — SwiftUI has no built-in flow layout on the
/// deployment target, and a horizontal ScrollView would hide half the looks behind a scroll.
struct FlowRow<Content: View>: View {
    let ids: [String]
    let content: (String) -> Content
    private let perRow = 3

    init(_ ids: [String], @ViewBuilder content: @escaping (String) -> Content) {
        self.ids = ids; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(stride(from: 0, to: ids.count, by: perRow)), id: \.self) { start in
                HStack(spacing: 6) {
                    ForEach(ids[start..<min(start + perRow, ids.count)], id: \.self) { content($0) }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
