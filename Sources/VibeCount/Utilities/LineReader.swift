import Foundation

/// Streams `\n`-separated UTF-8 lines from a file via chunked reads, so a
/// multi-megabyte session log is never held in memory at once.
final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var atEOF = false
    private let chunkSize: Int

    init(url: URL, chunkSize: Int = 64 * 1024) throws {
        self.handle = try FileHandle(forReadingFrom: url)
        self.chunkSize = chunkSize
    }

    deinit {
        // A failed close on a read-only handle is inconsequential.
        try? handle.close()
    }

    /// The next line without its trailing newline, or nil at end of file.
    func nextLine() throws -> String? {
        while true {
            if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                return String(decoding: lineData, as: UTF8.self)
            }
            if atEOF {
                guard !buffer.isEmpty else { return nil }
                let lineData = buffer
                buffer = Data()
                return String(decoding: lineData, as: UTF8.self)
            }
            if let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                buffer.append(chunk)
            } else {
                atEOF = true
            }
        }
    }
}
