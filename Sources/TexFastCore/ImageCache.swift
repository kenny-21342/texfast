import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Content-addressed cache of downsampled JPEGs.
///
/// The whole point is `xdvipdfmx`'s DCTDecode passthrough: a JPEG is copied into
/// the PDF verbatim, while every PNG is inflated and re-deflated on each run.
/// On the IB Physics notes that difference is 22 s -> 0.8 s in the PDF-writing
/// phase, which is most of the speedup.
struct ImageCache {
    let dir: URL
    let maxEdge: Int
    let quality: Float

    /// Raster formats worth converting. Vector art is already cheap and must not
    /// be rasterised.
    static let rasterExtensions: Set<String> = ["png", "jpg", "jpeg", "bmp", "tif", "tiff", "gif"]
    static let searchExtensions = ["", ".png", ".jpg", ".jpeg", ".pdf", ".PNG", ".JPG", ".JPEG"]

    init(dir: URL, maxEdge: Int = 800, quality: Float = 0.82) {
        self.dir = dir
        self.maxEdge = maxEdge
        self.quality = quality
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Resolve the name as `\includegraphics` would, relative to the project dir.
    static func resolve(_ name: String, in projectDir: URL) -> URL? {
        for ext in searchExtensions {
            let candidate = projectDir.appendingPathComponent(name + ext)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Returns the cache filename (not a full path) for an image, converting it
    /// on a miss. Returns nil when the image should be used as-is.
    /// `converted` distinguishes a real conversion from a cache hit, so the
    /// build summary does not claim work it did not do.
    func cachedName(for original: URL) -> (name: String, converted: Bool)? {
        let ext = original.pathExtension.lowercased()
        guard ImageCache.rasterExtensions.contains(ext) else { return nil }
        guard let data = try? Data(contentsOf: original) else { return nil }

        let key = TeXScanner.md5Hex(data) + "-\(maxEdge)-\(Int(quality * 100))"
        let name = "i\(key).jpg"
        let out = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: out.path) { return (name, false) }

        guard convert(data: data, to: out) else { return nil }
        return (name, true)
    }

    private func convert(data: Data, to out: URL) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return false }

        let w = image.width, h = image.height
        let longest = max(w, h)
        let scale = longest > maxEdge ? Double(maxEdge) / Double(longest) : 1.0
        let nw = max(1, Int((Double(w) * scale).rounded()))
        let nh = max(1, Int((Double(h) * scale).rounded()))

        guard let ctx = CGContext(data: nil,
                                  width: nw, height: nh,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        // JPEG has no alpha, so flatten onto white rather than onto black.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: nw, height: nh))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))

        guard let scaled = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}
