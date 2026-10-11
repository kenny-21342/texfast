import XCTest
@testable import TexFastCore

final class RealtimeEditTests: XCTestCase {
    func testUTF8ReplacementNeverSplitsScalars() {
        for (old, new) in [("a你🙂z", "a好🙂z"), ("café", "caffè"), ("café", "cafe\u{301}"), ("a\u{301}b", "a\u{302}b"),
                           ("abc", ""), ("", "你好"), ("same", "same"), ("\\alpha", "\\beta")] {
            guard let edit = RealtimeEdit.between(old, new) else { XCTAssertTrue(old.utf8.elementsEqual(new.utf8)); continue }
            let data = Data(old.utf8)
            XCTAssertNotNil(String(data: data[..<edit.start], encoding: .utf8))
            XCTAssertNotNil(String(data: data[edit.end...], encoding: .utf8))
            let result = data[..<edit.start] + Data(edit.text.utf8) + data[edit.end...]
            XCTAssertEqual(String(data: result, encoding: .utf8), new)
        }
        let edit = RealtimeEdit.between("a你🙂z", "a好🙂z")!
        XCTAssertEqual(edit.start, 1)
        XCTAssertEqual(edit.end, 4)
        XCTAssertEqual(edit.text, "好")
    }
}
