import Foundation
import TexFastCore

struct CompletionItem {
    let label: String
    let detail: String?
    let insertText: String
    let kindRank: Int
    let edit: CompletionEdit?
}

struct CompletionEdit {
    let startLine: Int
    let startCharacter: Int
    let endLine: Int
    let endCharacter: Int
}

struct Diagnostic {
    let line: Int          // 0-based
    let character: Int
    let message: String
    let severity: Int      // 1 error, 2 warning, 3 info, 4 hint
}

struct OutlineItem {
    let name: String
    let line: Int
    let depth: Int
}

/// texlab reports sections as Module symbols; it also reports macro definitions
/// (Struct) and list environments (Enum), which are noise in a section outline.
private let outlineSectionKind = 2

/// Minimal JSON-RPC client for `texlab`.
///
/// texlab already understands LaTeX properly — commands, environments, labels,
/// citations, package names, diagnostics, document symbols — so the editor asks
/// it rather than reimplementing any of that.
final class LSPClient {
    private let process = Process()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private var buffer = Data()
    private var nextID = 1
    private var handlers: [Int: (Any?) -> Void] = [:]
    private let lock = NSLock()
    private let rootURI: URL

    var onDiagnostics: ((URL, [Diagnostic]) -> Void)?
    private(set) var isRunning = false
    /// The server ignores everything sent before it answers `initialize`, so
    /// traffic is held until the handshake completes and then flushed in order.
    private var initialized = false
    private var pending: [[String: Any]] = []

    init?(rootURI: URL) {
        guard let exe = Shell.which("texlab") else { return nil }
        self.rootURI = rootURI
        process.executableURL = URL(fileURLWithPath: exe)
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
    }

    func start() {
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.ingest(chunk)
        }
        do { try process.run() } catch { return }
        isRunning = true

        request("initialize", [
            "processId": NSNumber(value: ProcessInfo.processInfo.processIdentifier),
            "rootUri": rootURI.absoluteString,
            "capabilities": [
                "textDocument": [
                    "completion": ["completionItem": ["snippetSupport": false]],
                    "publishDiagnostics": [:],
                    "documentSymbol": ["hierarchicalDocumentSymbolSupport": true]
                ]
            ]
        ]) { [weak self] _ in
            guard let self else { return }
            notify("initialized", [:])
            lock.lock()
            initialized = true
            let queued = pending
            pending = []
            lock.unlock()
            queued.forEach(write)
        }
    }

    func stop() {
        guard isRunning else { return }
        outPipe.fileHandleForReading.readabilityHandler = nil
        process.terminate()
        isRunning = false
    }

    // MARK: - document sync

    func didOpen(_ url: URL, text: String) {
        notify("textDocument/didOpen", ["textDocument": [
            "uri": url.absoluteString, "languageId": "latex", "version": 1, "text": text
        ]])
    }

    func didClose(_ url: URL) {
        notify("textDocument/didClose", ["textDocument": ["uri": url.absoluteString]])
    }

    private var version = 1
    func didChange(_ url: URL, text: String) {
        version += 1
        notify("textDocument/didChange", [
            "textDocument": ["uri": url.absoluteString, "version": version],
            "contentChanges": [["text": text]]     // full sync keeps this simple and correct
        ])
    }

    func didSave(_ url: URL) {
        notify("textDocument/didSave", ["textDocument": ["uri": url.absoluteString]])
    }

    // MARK: - requests

    func completion(_ url: URL, line: Int, character: Int, reply: @escaping ([CompletionItem]) -> Void) {
        request("textDocument/completion", [
            "textDocument": ["uri": url.absoluteString],
            "position": ["line": line, "character": character]
        ]) { result in
            var items: [[String: Any]] = []
            if let dict = result as? [String: Any], let list = dict["items"] as? [[String: Any]] {
                items = list
            } else if let list = result as? [[String: Any]] {
                items = list
            }
            let parsed: [CompletionItem] = items.compactMap { item in
                guard let label = item["label"] as? String else { return nil }
                var insert = item["insertText"] as? String ?? label
                if let edit = item["textEdit"] as? [String: Any], let newText = edit["newText"] as? String {
                    insert = newText
                }
                let detail = (item["detail"] as? String) ?? (item["documentation"] as? String)
                var parsedEdit: CompletionEdit?
                if let edit = item["textEdit"] as? [String: Any],
                   let range = edit["range"] as? [String: Any],
                   let start = range["start"] as? [String: Int],
                   let end = range["end"] as? [String: Int],
                   let startLine = start["line"], let startCharacter = start["character"],
                   let endLine = end["line"], let endCharacter = end["character"] {
                    parsedEdit = CompletionEdit(startLine: startLine, startCharacter: startCharacter,
                                                endLine: endLine, endCharacter: endCharacter)
                }
                return CompletionItem(label: label, detail: detail, insertText: insert,
                                      kindRank: item["kind"] as? Int ?? 99, edit: parsedEdit)
            }
            DispatchQueue.main.async { reply(parsed) }
        }
    }

    func documentSymbols(_ url: URL, reply: @escaping ([OutlineItem]) -> Void) {
        request("textDocument/documentSymbol", ["textDocument": ["uri": url.absoluteString]]) { result in
            var out: [OutlineItem] = []
            func walk(_ nodes: [[String: Any]], _ depth: Int) {
                for n in nodes {
                    guard let name = n["name"] as? String else { continue }
                    guard (n["kind"] as? Int) == outlineSectionKind else {
                        // Not a section itself, but a section may still be nested inside.
                        if let kids = n["children"] as? [[String: Any]] { walk(kids, depth) }
                        continue
                    }
                    let line = ((n["range"] as? [String: Any])?["start"] as? [String: Any])?["line"] as? Int
                        ?? ((n["location"] as? [String: Any])?["range"] as? [String: Any])
                            .flatMap { ($0["start"] as? [String: Any])?["line"] as? Int }
                        ?? 0
                    out.append(OutlineItem(name: name, line: line, depth: depth))
                    if let kids = n["children"] as? [[String: Any]] { walk(kids, depth + 1) }
                }
            }
            if let nodes = result as? [[String: Any]] { walk(nodes, 0) }
            DispatchQueue.main.async { reply(out) }
        }
    }

    // MARK: - transport

    private func request(_ method: String, _ params: [String: Any], reply: @escaping (Any?) -> Void) {
        lock.lock()
        let id = nextID
        nextID += 1
        handlers[id] = reply
        lock.unlock()
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func send(_ message: [String: Any]) {
        let method = message["method"] as? String
        guard isRunning || method == "initialize" else { return }
        if !initialized, method != "initialize", method != "initialized" {
            lock.lock(); pending.append(message); lock.unlock()
            return
        }
        write(message)
    }

    private func write(_ message: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        var out = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        out.append(body)
        do {
            try inPipe.fileHandleForWriting.write(contentsOf: out)
        } catch {
            // texlab went away; carry on without completion rather than dying.
            isRunning = false
        }
    }

    private func ingest(_ chunk: Data) {
        buffer.append(chunk)
        // Frames are `Content-Length: N\r\n\r\n` followed by exactly N bytes.
        while true {
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let header = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) ?? ""
            var length = 0
            for line in header.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
                length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            }
            let bodyStart = headerEnd.upperBound
            guard length > 0, buffer.count - (bodyStart - buffer.startIndex) >= length else { return }
            let body = buffer[bodyStart..<(bodyStart + length)]
            buffer.removeSubrange(buffer.startIndex..<(bodyStart + length))
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                dispatch(json)
            }
        }
    }

    private func dispatch(_ message: [String: Any]) {
        if let id = message["id"] as? Int {
            lock.lock(); let handler = handlers.removeValue(forKey: id); lock.unlock()
            handler?(message["result"])
            return
        }
        guard message["method"] as? String == "textDocument/publishDiagnostics",
              let params = message["params"] as? [String: Any],
              let uri = params["uri"] as? String,
              let url = URL(string: uri), url.isFileURL,
              let raw = params["diagnostics"] as? [[String: Any]] else { return }
        let diags: [Diagnostic] = raw.compactMap { d in
            guard let message = d["message"] as? String,
                  let range = d["range"] as? [String: Any],
                  let start = range["start"] as? [String: Any],
                  let line = start["line"] as? Int else { return nil }
            return Diagnostic(line: line,
                              character: start["character"] as? Int ?? 0,
                              message: message,
                              severity: d["severity"] as? Int ?? 1)
        }
        DispatchQueue.main.async { [weak self] in self?.onDiagnostics?(url.standardizedFileURL, diags) }
    }
}
