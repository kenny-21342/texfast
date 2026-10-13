import XCTest
@testable import TexFastCore

final class RealtimeSourceMapTests: XCTestCase {
    let spans: [[String: Any]] = [["id": 1, "range": ["start": 10, "end": 110]]]
    let placements: [[String: Any]] = [["par_id": 1, "fragments": [
        ["page": 1, "x": 20.0, "xs": [21.0, 22.0], "baselines": [100.0, 120.0]],
        ["page": 2, "x": 30.0, "baselines": [140.0, 160.0]]
    ]]]
    func testFollowsRowsAcrossPageFragmentsLikeThePlugin() {
        XCTAssertNil(RealtimeSourceMap.target(byte: 9, spans: spans, placements: placements))
        XCTAssertEqual(RealtimeSourceMap.target(byte: 40, spans: spans, placements: placements), RealtimeCursorTarget(page: 1, x: 22, y: 120))
        XCTAssertEqual(RealtimeSourceMap.target(byte: 65, spans: spans, placements: placements), RealtimeCursorTarget(page: 2, x: 30, y: 140))
        XCTAssertEqual(RealtimeSourceMap.target(byte: 999, spans: spans, placements: placements)?.y, 160)
    }
    func testLiveRowsReanchorAcrossPagesAndKeepOverflow() {
        let fragments = placements[0]["fragments"] as! [[String: Any]]
        let rows: [[String: Any]] = (0..<5).map { ["x": Double($0 * 3), "y": Double($0 * 12)] }
        let result = RealtimeSourceMap.reanchor(placements: fragments, rows: rows)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0]["xs"] as? [Double], [21, 24])
        XCTAssertEqual(result[0]["baselines"] as? [Double], [100, 112])
        XCTAssertEqual(result[1]["xs"] as? [Double], [30, 33, 36])
        XCTAssertEqual(result[1]["baselines"] as? [Double], [140, 152, 164])
        XCTAssertEqual(result[1]["approximate"] as? Bool, true)
        XCTAssertEqual(result[1]["first_line"] as? Int, 3)
        XCTAssertEqual(result[1]["last_line"] as? Int, 5)
        XCTAssertTrue(RealtimeSourceMap.reanchor(placements: [], rows: rows).isEmpty)
    }
    func testPagePreviewReplacesOnlyItsOwnFragmentsAndAddsNewUnits() {
        let incoming: [[String: Any]] = [
            ["par_id": 1, "fragments": [["page": 1, "first_line": 1, "last_line": 3, "baselines": [101.0, 121.0, 141.0]]]],
            ["par_id": 2, "fragments": [["page": 1, "first_line": 1, "last_line": 1, "baselines": [180.0]]]]
        ]
        let merged = RealtimeSourceMap.mergePage(1, incoming: incoming, into: placements)
        let first = merged.first { $0["par_id"] as? Int == 1 }!["fragments"] as! [[String: Any]]
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first[0]["baselines"] as? [Double], [101, 121, 141])
        XCTAssertEqual(first[1]["baselines"] as? [Double], [140, 160])
        XCTAssertNotNil(merged.first { $0["par_id"] as? Int == 2 })
        let cleared = RealtimeSourceMap.mergePage(1, incoming: [], into: merged)
        XCTAssertEqual((cleared[0]["fragments"] as? [[String: Any]])?.count, 1)
    }
    func testUTF16CaretColumnsMapToEngineUTF8Offsets() {
        let text = "你好\n😀café\n"
        XCTAssertEqual(RealtimeSourceMap.byteOffset(text: text, line: 2, column: 3), 11)
        XCTAssertEqual(RealtimeSourceMap.byteOffset(text: text, line: 2, column: 7), 16)
        XCTAssertEqual(RealtimeSourceMap.byteOffset(text: text, line: 999, column: 999), text.utf8.count)
    }
    func testUnplacedUnitsDoNotMoveThePreview() {
        XCTAssertNil(RealtimeSourceMap.target(byte: 30, spans: spans, placements: []))
    }
}
