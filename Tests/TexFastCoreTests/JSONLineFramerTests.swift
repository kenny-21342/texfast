import Foundation
import XCTest
@testable import TexFastCore

final class JSONLineFramerTests: XCTestCase {
    func testFragmentedUnicodeAndMultipleMessages() {
        let messages = ["{\"text\":\"你好 café\"}", "", "{\"event\":\"Ready\"}"]
        let bytes = Data((messages.joined(separator: "\n") + "\npartial").utf8)
        var framer = JSONLineFramer(), output: [Data] = []
        for byte in bytes { output += framer.append(Data([byte])) }
        XCTAssertEqual(output, messages.map { Data($0.utf8) })
        XCTAssertEqual(framer.append(Data(" end\n".utf8)), [Data("partial end".utf8)])
    }

    func testLargeLayoutAcrossPipeChunks() {
        let payload = Data((String(repeating: "{\"glyph\":123},", count: 1_000_000) + "\n").utf8)
        var framer = JSONLineFramer(), output: [Data] = []
        for start in stride(from: 0, to: payload.count, by: 4096) {
            output += framer.append(payload[start..<min(start + 4096, payload.count)])
        }
        XCTAssertEqual(output, [payload.dropLast()])
    }
}
