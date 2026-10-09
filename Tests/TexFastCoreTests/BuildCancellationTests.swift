import Foundation
import XCTest
@testable import TexFastCore

final class BuildCancellationTests: XCTestCase {
    func testCancelsAnActiveProcessPromptly() {
        let token = BuildCancellation()
        let started = Date()
        var sawReady = false

        let result = Shell.run("/bin/sh", ["-c", "echo ready; exec /bin/sleep 10"],
                               cwd: URL(fileURLWithPath: NSTemporaryDirectory()),
                               cancellation: token,
                               onOutput: { output in
                                   if output.contains("ready") {
                                       sawReady = true
                                       token.cancel()
                                   }
                               })

        XCTAssertTrue(sawReady)
        XCTAssertEqual(result.status, -1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testCancelledTokenDoesNotLaunchProcess() {
        let token = BuildCancellation()
        token.cancel()
        let result = Shell.run("/bin/sleep", ["10"],
                               cwd: URL(fileURLWithPath: NSTemporaryDirectory()),
                               cancellation: token)
        XCTAssertEqual(result.status, -1)
        XCTAssertEqual(result.duration, 0)
    }

    func testDriverCanBuildAgainAfterCancellation() throws {
        guard Shell.which("lualatex") != nil else { throw XCTSkip("LuaLaTeX is unavailable") }
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("texfast-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }

        let source = project.appendingPathComponent("main.tex")
        let initial = "\\documentclass{article}\n\\begin{document}Original\\end{document}\n"
        try initial.write(to: source, atomically: true, encoding: .utf8)
        let driver = Driver(texFile: source, projectDir: project,
                            cacheDir: project.appendingPathComponent(".texfast"),
                            draft: true, jobs: 1)
        let original = driver.build(figuresOnly: false, previewOnly: true)
        let originalPDF = try Data(contentsOf: XCTUnwrap(original.pdf))
        let originalSync = try Data(contentsOf: driver.synctexFile)

        let slow = """
        \\documentclass{article}
        \\begin{document}
        \\directlua{local t=os.clock(); while os.clock()-t < 10 do end}
        Old version
        \\end{document}
        """
        try slow.write(to: source, atomically: true, encoding: .utf8)
        let cancellation = BuildCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            cancellation.cancel()
        }
        let first = driver.build(figuresOnly: false, previewOnly: true,
                                 cancellation: cancellation)
        XCTAssertTrue(first.cancelled)
        XCTAssertNil(first.pdf)
        XCTAssertEqual(try Data(contentsOf: driver.draftPDF), originalPDF)
        XCTAssertEqual(try Data(contentsOf: driver.synctexFile), originalSync)

        let fresh = "\\documentclass{article}\n\\begin{document}New version\\end{document}\n"
        try fresh.write(to: source, atomically: true, encoding: .utf8)
        let second = driver.build(figuresOnly: false, previewOnly: true)
        XCTAssertNil(second.error)
        XCTAssertFalse(second.cancelled)
        XCTAssertNotNil(second.pdf)
    }
}
