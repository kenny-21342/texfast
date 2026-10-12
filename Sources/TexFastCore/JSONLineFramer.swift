import Foundation

/// Scan each incoming byte once. A large, fragmented layout must not repeatedly
/// search the entire accumulated message for its terminating newline.
public struct JSONLineFramer {
    private var partial = Data()
    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        var lines: [Data] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            for index in bytes.indices where bytes[index] == 10 {
                partial.append(contentsOf: bytes[start..<index])
                lines.append(partial)
                partial = Data()
                start = index + 1
            }
            partial.append(contentsOf: bytes[start..<bytes.count])
        }
        return lines
    }
}
