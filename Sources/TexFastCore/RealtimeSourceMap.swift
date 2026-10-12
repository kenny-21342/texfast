import Foundation

public struct RealtimeCursorTarget: Equatable {
    public let page: Int
    public let x: Double
    public let y: Double
}

/// Matches the plugin's spanAt / targetInFragments mapping, in UTF-8 bytes and sp.
public enum RealtimeSourceMap {
    /// Re-anchor a live unit when pagination advances, preserving its relative rows.
    public static func reanchor(placements: [[String: Any]], rows: [[String: Any]]) -> [[String: Any]] {
        var anchors: [(Int, Double, Double)] = []
        for fragment in placements {
            guard let page = fragment["page"] as? Int else { continue }
            let ys = fragment["baselines"] as? [Double] ?? [], xs = fragment["xs"] as? [Double] ?? []
            for (i, y) in ys.enumerated() { anchors.append((page, i < xs.count ? xs[i] : fragment["x"] as? Double ?? 0, y)) }
        }
        var result: [[String: Any]] = [], i = 0
        while i < anchors.count && i < rows.count {
            let anchor = anchors[i], first = i
            let ax = (rows[i]["x"] as? NSNumber)?.doubleValue ?? 0, ay = (rows[i]["y"] as? NSNumber)?.doubleValue ?? 0
            var xs: [Double] = [], ys: [Double] = []
            func add(_ index: Int) {
                xs.append(anchor.1 + ((rows[index]["x"] as? NSNumber)?.doubleValue ?? 0) - ax)
                ys.append(anchor.2 + ((rows[index]["y"] as? NSNumber)?.doubleValue ?? 0) - ay)
            }
            while i < anchors.count && anchors[i].0 == anchor.0 && i < rows.count { add(i); i += 1 }
            var approximate = false
            if i >= anchors.count { while i < rows.count { add(i); i += 1; approximate = true } }
            result.append(["page": anchor.0, "first_line": first + 1, "last_line": i, "x": xs[0], "xs": xs,
                           "baselines": ys, "approximate": approximate])
        }
        return result
    }

    public static func byteOffset(text: String, line: Int, column: Int) -> Int {
        let lines = text.components(separatedBy: "\n")
        let index = min(max(0, line - 1), lines.count - 1)
        let value = lines[index] as NSString
        return lines.prefix(index).reduce(0) { $0 + $1.utf8.count + 1 }
            + value.substring(to: min(max(0, column - 1), value.length)).utf8.count
    }

    public static func target(byte: Int, spans: [[String: Any]], placements: [[String: Any]]) -> RealtimeCursorTarget? {
        let span = spans.filter { (($0["range"] as? [String: Int])?["start"] ?? Int.max) <= byte }
            .max { (($0["range"] as? [String: Int])?["start"] ?? 0) < (($1["range"] as? [String: Int])?["start"] ?? 0) }
        guard let span, let id = span["id"] as? Int, let range = span["range"] as? [String: Int],
              let start = range["start"], let end = range["end"],
              let placement = placements.first(where: { $0["par_id"] as? Int == id }),
              let fragments = placement["fragments"] as? [[String: Any]] else { return nil }
        let total = fragments.reduce(0) { $0 + (($1["baselines"] as? [Double])?.count ?? 0) }
        guard total > 0 else { return nil }
        let fraction = Double(byte - start) / Double(max(1, end - start))
        var row = min(total - 1, max(0, Int(floor(fraction * Double(total)))))
        for fragment in fragments {
            let baselines = fragment["baselines"] as? [Double] ?? []
            if row < baselines.count, let page = fragment["page"] as? Int {
                let xs = fragment["xs"] as? [Double] ?? []
                return RealtimeCursorTarget(page: page, x: row < xs.count ? xs[row] : fragment["x"] as? Double ?? 0,
                                            y: baselines[row])
            }
            row -= baselines.count
        }
        return nil
    }
}
