import AppKit
import CoreText
import ImageIO
import PDFKit
import TexFastCore

private let spPerBP = 65781.76
private func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
private func point(_ x: Any?, _ y: Any?) -> CGPoint { CGPoint(x: number(x) / spPerBP, y: number(y) / spPerBP) }

/// Immutable drawing prepared off the main thread from the engine's exact glyph positions.
struct NativeLiveUnit {
    let id: Int
    let revision: Int
    let pages: [Int: NativeLivePage]
}
struct NativeLivePage {
    let masks: [CGRect]
    let drawing: [NativeLiveOperation]
    var bounds: CGRect { masks.reduce(CGRect.null) { $0.union($1) } }
}
enum NativeLiveOperation {
    case fill(CGPath, CGColor, Bool)
    case glyph(CTFont, CGGlyph, CGAffineTransform, CGColor)
    case image(CGImage, CGRect, CGAffineTransform)
    case pdf(CGPDFDocument, CGPDFPage, CGRect, CGAffineTransform)
    case save, restore
    case clip(CGPath, Bool)
    func draw(in context: CGContext) {
        switch self {
        case let .glyph(font, glyph, transform, color):
            context.saveGState(); context.concatenate(transform); context.setFillColor(color)
            context.textMatrix = .identity
            var glyph = glyph, origin = CGPoint.zero
            CTFontDrawGlyphs(font, &glyph, &origin, 1, context)
            context.restoreGState()
        case let .fill(path, color, evenOdd):
            context.setFillColor(color); context.addPath(path)
            context.drawPath(using: evenOdd ? .eoFill : .fill)
        case let .image(image, rect, matrix):
            context.saveGState(); context.concatenate(matrix)
            context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .none
            context.setShouldAntialias(false) // LuaTeX images use non-interpolated PDF image edges
            context.draw(image, in: CGRect(origin: .zero, size: rect.size)); context.restoreGState()
        case let .pdf(owner, page, rect, matrix):
            context.saveGState(); context.concatenate(matrix)
            context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
            let source = page.getBoxRect(.mediaBox)
            context.scaleBy(x: rect.width / source.width, y: rect.height / source.height)
            context.translateBy(x: -source.minX, y: -source.minY)
            withExtendedLifetime(owner) { context.drawPDFPage(page) }; context.restoreGState()
        case .save: context.saveGState()
        case .restore: context.restoreGState()
        case let .clip(path, evenOdd): context.addPath(path); context.clip(using: evenOdd ? .evenOdd : .winding)
        }
    }
}

/// CoreGraphics reads TeX's actual OTF/TTF/PFB files; no substituted system fonts.
private final class NativeFont {
    let cg: CGFont
    let encoding: [Int: String]
    let slant: Double
    let extend: Double
    private var sized: [Double: CTFont] = [:]
    private var glyphs: [Int: CGGlyph] = [:]
    init(cg: CGFont, encoding: [Int: String], slant: Double, extend: Double) {
        self.cg = cg
        self.encoding = encoding; self.slant = slant; self.extend = extend
    }
    func glyph(index: Any?, char: Int) -> CGGlyph? {
        if let n = index as? NSNumber { return CGGlyph(exactly: n.intValue) }
        if let cached = glyphs[char] { return cached }
        guard let name = encoding[char] else { return nil }
        let glyph = cg.getGlyphWithGlyphName(name: name as CFString)
        if glyph == 0 && name != ".notdef" { return nil }
        glyphs[char] = glyph
        return glyph
    }
    func atSize(_ points: Double) -> CTFont {
        if let cached = sized[points] { return cached }
        let font = CTFontCreateWithGraphicsFont(cg, points, nil, nil)
        sized[points] = font
        return font
    }
}

private struct NativeItemReference: Hashable { let row: Int?; let item: Int }
private struct NativeGraphicsIndex {
    var operations: [NativeItemReference: [[String: Any]]] = [:]
    var transforms: [NativeItemReference: CGAffineTransform] = [:]
    init(_ native: [String: Any]) {
        for op in native["ops"] as? [[String: Any]] ?? [] {
            if let at = op["at"] as? [String: Any], let item = at["item"] as? Int {
                operations[NativeItemReference(row: at["line"] as? Int, item: item), default: []].append(op)
            }
        }
        for transform in native["transforms"] as? [[Any]] ?? [] where transform.count == 2 {
            if let at = transform[0] as? [String: Any], let item = at["item"] as? Int,
               let v = transform[1] as? [Double], v.count == 6 {
                transforms[NativeItemReference(row: at["line"] as? Int, item: item)] =
                    CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4] / spPerBP, ty: v[5] / spPerBP)
            }
        }
    }
}

final class NativeLiveRenderer {
    private let root: URL
    private var fonts: [String: NativeFont] = [:]
    private var failedFonts = Set<String>()
    private var locations: [String: URL] = [:]
    private var fontMap: [String: String]?
    private var images: [String: CGImage] = [:]
    private var pdfImages: [String: CGPDFDocument] = [:]
    private var imageStamps: [String: Date] = [:]
    private var warmed = false
    private var pages: [Int: [String: Any]] = [:]
    private var dirtyPages = Set<Int>()
    private var originalMasks: [Int: [Int: [CGRect]]] = [:]
    init(root: URL) { self.root = root }

    /// Keep the engine's page deltas even when a stale PDF is not displayed.
    /// The next accepted pass may omit pages unchanged since that stale pass.
    func recordLayoutPages(_ event: [String: Any]) {
        for page in event["pages_changed"] as? [[String: Any]] ?? [] {
            guard let n = page["page"] as? Int, let dl = page["dl"] as? [String: Any] else { continue }
            pages[n] = dl; dirtyPages.insert(n)
        }
    }

    /// Warm resources before enabling editing and retain row geometry for masking old text.
    func installLayout(_ event: [String: Any]) {
        recordLayoutPages(event)
        // Retry unavailable resources on the next complete layout, not once per glyph.
        failedFonts.removeAll(keepingCapacity: true)
        for (file, stamp) in imageStamps {
            if let url = locations[file], imageStamp(url) != stamp {
                images.removeValue(forKey: file); pdfImages.removeValue(forKey: file)
                imageStamps.removeValue(forKey: file)
            }
        }
        for n in dirtyPages.sorted() {
            guard let dl = pages[n] else { continue }
            for desc in (dl["fonts"] as? [String: [String: Any]] ?? [:]).values { _ = font(desc) }
            if !warmed { for info in (dl["images_info"] as? [String: [String: Any]] ?? [:]).values { _ = image(info) } }
            // Warm glyph lookup and CoreText sizes, keeping font setup off the per-keystroke path.
            let descriptors = dl["fonts"] as? [String: [String: Any]] ?? [:]
            for row in dl["lines"] as? [[String: Any]] ?? [] {
                for item in row["items"] as? [[Any]] ?? [] where item.first as? String == "g" && item.count >= 8 {
                    if let desc = descriptors[String(Int(number(item[1])))], let font = font(desc),
                       let glyph = font.glyph(index: item[3], char: Int(number(item[2]))) { _ = glyph; _ = font.atSize(number(desc["size"]) / spPerBP) }
                }
            }
        }
        dirtyPages.removeAll(keepingCapacity: true)
        warmed = true
        let total = event["pages_total"] as? Int ?? 0
        pages = pages.filter { $0.key <= total }
        originalMasks.removeAll(keepingCapacity: true)
        for placement in event["placements"] as? [[String: Any]] ?? [] {
            guard let id = placement["par_id"] as? Int else { continue }
            for fragment in placement["fragments"] as? [[String: Any]] ?? [] {
                guard let n = fragment["page"] as? Int, let page = pages[n] else { continue }
                let rows = page["lines"] as? [[String: Any]] ?? []
                let baselines = fragment["baselines"] as? [Double] ?? []
                let xs = fragment["xs"] as? [Double] ?? []
                // Anchor to exact rows, then include other rows of that capture unit.
                // This catches nested display/picture rows without erasing footnotes or columns.
                var owned = Set<Int>(), captureUnits = Set<Int>()
                for (i, baseline) in baselines.enumerated() {
                    let x = i < xs.count ? xs[i] : number(fragment["x"])
                    for (index, row) in rows.enumerated() where abs(number(row["y"]) - baseline) <= 64 && abs(number(row["x"]) - x) <= 64 {
                        owned.insert(index)
                        if let unit = row["unit"] as? Int, unit > 0 { captureUnits.insert(unit) }
                    }
                }
                for (index, row) in rows.enumerated() {
                    if owned.contains(index) || captureUnits.contains(Int(number(row["unit"]))) {
                        originalMasks[id, default: [:]][n, default: []].append(band(row, offset: .zero))
                    }
                }
            }
        }
    }

    /// Unsupported material keeps its last complete drawing until the next background PDF.
    func prepare(_ event: [String: Any]) -> NativeLiveUnit? {
        guard let id = event["par_id"] as? Int,
              let revision = (event["versions"] as? [String: Any])?["source_revision"] as? Int,
              let masks = originalMasks[id], !masks.isEmpty else { return nil }
        if event["status"] as? String == "removed" {
            return NativeLiveUnit(id: id, revision: revision, pages: masks.mapValues { NativeLivePage(masks: $0, drawing: []) })
        }
        guard let dl = event["dl"] as? [String: Any] else { return nil }
        guard ["ok", "ok_degraded"].contains(event["status"] as? String ?? "") else { return nil }
        let native = event["native"] as? [String: Any]
        let graphics = native.map(NativeGraphicsIndex.init)
        let flags = dl["flags"] as? [String: Any] ?? [:]
        guard flags.isEmpty || (native != nil && flags.keys.allSatisfy { $0 == "literal" || $0 == "shading" }) else { return nil }
        let rows = dl["lines"] as? [[String: Any]] ?? []
        let descs = dl["fonts"] as? [String: [String: Any]] ?? [:]
        var output: [Int: NativeLivePage] = masks.mapValues { NativeLivePage(masks: $0, drawing: []) }
        var color = CGColor(gray: 0, alpha: 1), stacks: [Int: [CGColor]] = [:]
        var drewOther = false
        for fragment in event["fragments"] as? [[String: Any]] ?? [] {
            guard let page = fragment["page"] as? Int, pages[page] != nil,
                  Int(number(pages[page]?["rotate"])) == 0 else { return nil }
            let first = Int(number(fragment["first_line"])) - 1
            let last = Int(number(fragment["last_line"])) - 1
            let baselines = fragment["baselines"] as? [Double] ?? []
            let xs = fragment["xs"] as? [Double] ?? []
            guard first >= 0, last < rows.count, last >= first, baselines.count == last - first + 1 else { return nil }
            var clear = output[page]?.masks ?? [], drawing = output[page]?.drawing ?? []
            for index in first...last {
                let row = rows[index], j = index - first
                let x = j < xs.count ? xs[j] : number(fragment["x"])
                let offset = CGPoint(x: (x - number(row["x"])) / spPerBP,
                                     y: (baselines[j] - number(row["y"])) / spPerBP)
                clear.append(band(row, offset: offset))
                if !drewOther {
                    drewOther = true
                    guard append(dl["other"] as? [[Any]] ?? [], row: nil, offset: offset, dl: dl, descs: descs,
                                 graphics: graphics, color: &color, stacks: &stacks, into: &drawing) else { return nil }
                }
                guard append(row["items"] as? [[Any]] ?? [], row: index, offset: offset, dl: dl, descs: descs,
                             graphics: graphics, color: &color, stacks: &stacks, into: &drawing) else { return nil }
            }
            output[page] = NativeLivePage(masks: clear, drawing: drawing)
        }
        return NativeLiveUnit(id: id, revision: revision, pages: output)
    }

    private func band(_ row: [String: Any], offset: CGPoint) -> CGRect {
        CGRect(x: number(row["x"]) / spPerBP + offset.x - 0.75,
               y: (number(row["y"]) - number(row["h"])) / spPerBP + offset.y - 0.75,
               width: number(row["w"]) / spPerBP + 1.5,
               height: max(1, (number(row["h"]) + number(row["d"])) / spPerBP) + 1.5)
    }

    private func append(_ items: [[Any]], row: Int?, offset: CGPoint, dl: [String: Any], descs: [String: [String: Any]],
                        graphics: NativeGraphicsIndex?, color: inout CGColor, stacks: inout [Int: [CGColor]],
                        into output: inout [NativeLiveOperation]) -> Bool {
        var matrix = CGAffineTransform.identity, matrices: [CGAffineTransform] = []
        for (index, item) in items.enumerated() {
            guard let kind = item.first as? String else { return false }
            let reference = NativeItemReference(row: row, item: index)
            let itemMatrix = graphics?.transforms[reference] ?? matrix
            switch kind {
            case "g":
                guard item.count >= 8, let desc = descs[String(Int(number(item[1])))] else { return false }
                if desc["filename"] as? String == nil && desc["name"] as? String == nil { break } // nullfont
                guard let font = font(desc), let glyph = font.glyph(index: item[3], char: Int(number(item[2]))) else { return false }
                let size = number(desc["size"]) / spPerBP
                let extend = number(desc["extend"]) == 0 ? 1 : number(desc["extend"]) / 1000
                let squeeze = number(desc["squeeze"]) == 0 ? 1 : number(desc["squeeze"]) / 1000
                let expansion = 1 + number(item[7]) / 1_000_000
                let transform = CGAffineTransform(a: extend * expansion * font.extend, b: 0,
                                                  c: number(desc["slant"]) / 1000 + font.slant, d: -squeeze,
                                                  tx: number(item[4]) / spPerBP, ty: number(item[5]) / spPerBP)
                    .concatenating(itemMatrix).concatenating(CGAffineTransform(translationX: offset.x, y: offset.y))
                output.append(.glyph(font.atSize(size), glyph, transform, color))
            case "r":
                guard item.count >= 5 else { return false }
                let rect = CGRect(x: number(item[1]) / spPerBP, y: number(item[2]) / spPerBP,
                                  width: number(item[3]) / spPerBP, height: number(item[4]) / spPerBP)
                var transform = itemMatrix.concatenating(CGAffineTransform(translationX: offset.x, y: offset.y))
                output.append(.fill(CGPath(rect: rect, transform: &transform), color, false))
            case "c":
                guard item.count >= 4 else { return false }
                let stack = Int(number(item[1])), command = Int(number(item[2]))
                let parsed = pdfColor(item[3] as? String ?? "")
                switch command {
                case 0:
                    if stacks[stack]?.isEmpty == false { stacks[stack]?.removeLast() }
                    stacks[stack, default: []].append(parsed ?? color)
                case 1: stacks[stack, default: []].append(parsed ?? color)
                case 2: if stacks[stack]?.isEmpty == false { stacks[stack]?.removeLast() }
                default: break
                }
                color = stacks[stack]?.last ?? CGColor(gray: 0, alpha: 1)
            case "m": break
            case "M":
                guard item.count >= 5 else { return false }
                switch item[1] as? String {
                case "save": matrices.append(matrix)
                case "restore": guard let previous = matrices.popLast() else { return false }; matrix = previous
                case "set":
                    let v = (item[4] as? String ?? "").split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
                    guard v.count == 4 else { return false }
                    let origin = point(item[2], item[3])
                    let next = CGAffineTransform(translationX: -origin.x, y: -origin.y)
                        .concatenating(CGAffineTransform(a: v[0], b: -v[1], c: -v[2], d: v[3], tx: 0, ty: 0))
                        .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
                    matrix = next.concatenating(matrix)
                default: return false
                }
            case "i":
                guard item.count >= 6, let info = (dl["images_info"] as? [String: [String: Any]])?[String(Int(number(item[1])))],
                      let resource = image(info) else { return false }
                let rect = CGRect(x: number(item[2]) / spPerBP, y: number(item[3]) / spPerBP,
                                  width: number(item[4]) / spPerBP, height: number(item[5]) / spPerBP)
                let transform = itemMatrix.concatenating(CGAffineTransform(translationX: offset.x, y: offset.y))
                switch resource {
                case let .bitmap(image): output.append(.image(image, rect, transform))
                case let .pdf(document, page): output.append(.pdf(document, page, rect, transform))
                }
            case "l", "u": guard graphics != nil else { return false }
            default: return false
            }
            for op in graphics?.operations[reference] ?? [] {
                guard appendNative(op, offset: offset, into: &output) else { return false }
            }
        }
        return matrices.isEmpty
    }

    private func appendNative(_ op: [String: Any], offset: CGPoint, into output: inout [NativeLiveOperation]) -> Bool {
        guard !(op["pattern"] is String), !(op["mask"] is String) else { return false }
        switch op["op"] as? String {
        case "Save": output.append(.save); return true
        case "Restore": output.append(.restore); return true
        case "Paint", "Clip":
            guard let values = op["ctm"] as? [Double], values.count == 6, let segments = op["path"] as? [[String: Any]] else { return false }
            let path = CGMutablePath()
            for segment in segments {
                switch segment["s"] as? String {
                case "M": path.move(to: CGPoint(x: number(segment["x"]), y: number(segment["y"])))
                case "L": path.addLine(to: CGPoint(x: number(segment["x"]), y: number(segment["y"])))
                case "C": path.addCurve(to: CGPoint(x: number(segment["x"]), y: number(segment["y"])),
                                         control1: CGPoint(x: number(segment["x1"]), y: number(segment["y1"])),
                                         control2: CGPoint(x: number(segment["x2"]), y: number(segment["y2"])))
                case "Z": path.closeSubpath()
                default: return false
                }
            }
            var transform = CGAffineTransform(a: values[0] / spPerBP, b: values[1] / spPerBP,
                                              c: values[2] / spPerBP, d: values[3] / spPerBP,
                                              tx: values[4] / spPerBP + offset.x, ty: values[5] / spPerBP + offset.y)
            guard let mapped = path.copy(using: &transform) else { return false }
            if op["op"] as? String == "Clip" { output.append(.clip(mapped, op["even_odd"] as? Bool ?? false)); return true }
            if let fill = op["fill"] as? [String: Any] { output.append(.fill(mapped, gfxColor(fill), op["even_odd"] as? Bool ?? false)) }
            if let stroke = op["stroke"] as? [String: Any], let color = stroke["color"] as? [String: Any] {
                var outline: CGPath = path
                if let dash = stroke["dash"] as? [Double], !dash.isEmpty {
                    outline = outline.copy(dashingWithPhase: number(stroke["dash_phase"]), lengths: dash.map { CGFloat($0) })
                }
                outline = outline.copy(strokingWithWidth: number(stroke["width"]),
                                       lineCap: CGLineCap(rawValue: Int32(number(stroke["cap"]))) ?? .butt,
                                       lineJoin: CGLineJoin(rawValue: Int32(number(stroke["join"]))) ?? .miter,
                                       miterLimit: number(stroke["miter_limit"]), transform: transform)
                output.append(.fill(outline, gfxColor(color), false))
            }
            return true
        default: return false // gradients, patterns/fadings and unrecognised ops use the full PDF
        }
    }

    private func pdfColor(_ data: String) -> CGColor? {
        let words = data.split(whereSeparator: \.isWhitespace).map(String.init)
        for (i, word) in words.enumerated() {
            let count = word == "g" ? 1 : word == "rg" ? 3 : word == "k" ? 4 : 0
            if count > 0, i >= count {
                let values = words[(i-count)..<i].compactMap(Double.init)
                if values.count == count { return rgb(values, alpha: 1) }
            }
        }
        return nil
    }
    private func gfxColor(_ color: [String: Any]) -> CGColor { rgb(color["comps"] as? [Double] ?? [0], alpha: number(color["alpha"])) }
    private func rgb(_ v: [Double], alpha: Double) -> CGColor {
        if v.count == 4 {
            // Let Quartz use the same CMYK conversion as the PDF, rather than a
            // simplistic RGB formula (which makes pgf cyan visibly too bright).
            return CGColor(colorSpace: CGColorSpaceCreateDeviceCMYK(), components: v.map { CGFloat($0) } + [CGFloat(alpha)])!
        }
        if v.count == 3 { return CGColor(red: v[0], green: v[1], blue: v[2], alpha: alpha) }
        return CGColor(gray: v.first ?? 0, alpha: alpha)
    }

    private func locate(_ name: String) -> URL? {
        if let cached = locations[name] { return cached }
        let direct = name.hasPrefix("/") ? URL(fileURLWithPath: name) : root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: direct.path) { locations[name] = direct; return direct }
        guard let kpse = Shell.which("kpsewhich") else { return nil }
        let result = Shell.run(kpse, [name], cwd: root)
        guard result.status == 0, let path = result.output.split(whereSeparator: \.isNewline).first else { return nil }
        let url = URL(fileURLWithPath: String(path)); locations[name] = url; return url
    }
    private func font(_ desc: [String: Any]) -> NativeFont? {
        let key = (desc["filename"] as? String).map { $0 + "#\(Int(number(desc["subfont"])))" } ?? (desc["name"] as? String ?? "")
        if let cached = fonts[key] { return cached }
        guard !failedFonts.contains(key) else { return nil }
        failedFonts.insert(key)
        var filename = desc["filename"] as? String, encoding: [Int: String] = [:], slant = 0.0, extend = 1.0
        if filename == nil {
            if fontMap == nil {
                fontMap = [:]
                if let url = locate("pdftex.map"), let text = try? String(contentsOf: url, encoding: .utf8) {
                    for line in text.split(whereSeparator: \.isNewline) {
                        if let name = line.split(whereSeparator: \.isWhitespace).first { fontMap?[String(name)] = String(line) }
                    }
                }
            }
            guard let name = desc["name"] as? String, let line = fontMap?[name] else { return nil }
            let downloads = line.split(whereSeparator: \.isWhitespace).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "<[")) }
            filename = downloads.first { $0.hasSuffix(".pfb") || $0.hasSuffix(".pfa") || $0.hasSuffix(".otf") || $0.hasSuffix(".ttf") }
            if let enc = downloads.first(where: { $0.hasSuffix(".enc") }), let url = locate(enc), let text = try? String(contentsOf: url, encoding: .isoLatin1) {
                encoding = parseEncoding(text)
            }
            let words = line.replacingOccurrences(of: "\"", with: " ").split(whereSeparator: \.isWhitespace).map(String.init)
            for i in 1..<words.count {
                if words[i] == "SlantFont", let value = Double(words[i-1]) { slant = value }
                if words[i] == "ExtendFont", let value = Double(words[i-1]) { extend = value }
            }
        }
        guard let filename, let url = locate(filename), let data = try? Data(contentsOf: url),
              let provider = CGDataProvider(data: data as CFData), var cg = CGFont(provider) else { return nil }
        // Lua font subfonts are one-based (0/1 both denote the first face).
        let subfont = max(0, Int(number(desc["subfont"])) - 1)
        if subfont > 0 {
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], subfont < descriptors.count else { return nil }
            cg = CTFontCopyGraphicsFont(CTFontCreateWithFontDescriptor(descriptors[subfont], 1000, nil), nil)
        }
        // The protocol does not describe variation axes, so keep variable faces
        // in the authoritative PDF rather than drawing a potentially wrong weight.
        if let axes = cg.variationAxes as? [Any], !axes.isEmpty { return nil }
        if encoding.isEmpty && ["pfb", "pfa"].contains(url.pathExtension.lowercased()) {
            encoding = parseEncoding(String(decoding: data.prefix(65536), as: UTF8.self))
        }
        let font = NativeFont(cg: cg, encoding: encoding, slant: slant, extend: extend)
        fonts[key] = font
        failedFonts.remove(key)
        return font
    }
    private func parseEncoding(_ text: String) -> [Int: String] {
        let regex = try! NSRegularExpression(pattern: #"dup\s+(\d+)\s+/([^\s]+)\s+put"#)
        let ns = text as NSString
        var result: [Int: String] = [:]
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if let n = Int(ns.substring(with: match.range(at: 1))) { result[n] = ns.substring(with: match.range(at: 2)) }
        }
        if !result.isEmpty { return result }
        let clean = text.components(separatedBy: .newlines).map { $0.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "" }.joined(separator: "\n")
        guard let start = clean.firstIndex(of: "["), let end = clean[start...].firstIndex(of: "]") else { return [:] }
        let names = clean[clean.index(after: start)..<end].split(whereSeparator: \.isWhitespace).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        return Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.offset, $0.element) })
    }

    private func imageStamp(_ url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    }
    private enum ImageResource { case bitmap(CGImage), pdf(CGPDFDocument, CGPDFPage) }
    private func image(_ info: [String: Any]) -> ImageResource? {
        guard let file = info["file"] as? String, info["cached_picture"] as? Bool != true else { return nil }
        let pageNumber = max(1, Int(number(info["page"])))
        if let cached = images[file] { return .bitmap(cached) }
        if let document = pdfImages[file], let page = document.page(at: pageNumber) {
            guard page.rotationAngle == 0, page.getBoxRect(.cropBox) == page.getBoxRect(.mediaBox) else { return nil }
            return .pdf(document, page)
        }
        guard let url = locate(file) else { return nil }
        imageStamps[file] = imageStamp(url)
        if url.pathExtension.lowercased() == "pdf", let document = CGPDFDocument(url as CFURL) {
            pdfImages[file] = document
            guard let page = document.page(at: pageNumber),
                  page.rotationAngle == 0, page.getBoxRect(.cropBox) == page.getBoxRect(.mediaBox) else { return nil }
            return .pdf(document, page)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        images[file] = image; return .bitmap(image)
    }
}
