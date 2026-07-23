import XCTest
@testable import VibeCount

/// Exercises `LineReader`'s chunked streaming — in particular the multi-chunk
/// buffer-append path and lines that straddle a chunk boundary, which the
/// monitor tests never reach because their fixtures fit in a single 64 KB read.
final class LineReaderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LineReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ contents: String) throws -> URL {
        let url = tempDir.appendingPathComponent("\(UUID().uuidString).log")
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    private func readAllLines(_ url: URL, chunkSize: Int) throws -> [String] {
        let reader = try LineReader(url: url, chunkSize: chunkSize)
        var lines: [String] = []
        while let line = try reader.nextLine() {
            lines.append(line)
        }
        return lines
    }

    // MARK: Multi-chunk behavior (the reason the type exists).

    func testLinesSpanningChunkBoundariesReassembleCorrectly() throws {
        // Tiny chunkSize (4 bytes) forces most lines to straddle >1 read.
        let url = try write("alpha\nbeta\ngamma\ndelta\n")
        let lines = try readAllLines(url, chunkSize: 4)
        XCTAssertEqual(lines, ["alpha", "beta", "gamma", "delta"])
    }

    func testSingleLineLongerThanManyChunks() throws {
        let long = String(repeating: "x", count: 5_000)
        let url = try write(long + "\n")
        let lines = try readAllLines(url, chunkSize: 64)
        XCTAssertEqual(lines, [long])
    }

    func testChunkBoundaryLandingExactlyOnNewline() throws {
        // "ab\n" is exactly 3 bytes; a 3-byte chunk ends right on the newline.
        let url = try write("ab\ncd\n")
        let lines = try readAllLines(url, chunkSize: 3)
        XCTAssertEqual(lines, ["ab", "cd"])
    }

    // MARK: Terminator / edge handling.

    func testFinalLineWithoutTrailingNewlineIsReturned() throws {
        let url = try write("first\nsecond")   // no trailing "\n"
        let lines = try readAllLines(url, chunkSize: 4)
        XCTAssertEqual(lines, ["first", "second"])
    }

    func testBlankLinesProduceEmptyStrings() throws {
        let url = try write("a\n\nb\n")
        let lines = try readAllLines(url, chunkSize: 4)
        XCTAssertEqual(lines, ["a", "", "b"])
    }

    func testEmptyFileYieldsNoLines() throws {
        let url = try write("")
        let lines = try readAllLines(url, chunkSize: 4)
        XCTAssertEqual(lines, [])
    }

    func testMultibyteUTF8AcrossChunkBoundary() throws {
        // "é" is 2 UTF-8 bytes; a 1-byte chunk splits it, so this proves the
        // reader defers decoding until it has whole lines, not raw bytes.
        let url = try write("café\nrésumé\n")
        let lines = try readAllLines(url, chunkSize: 1)
        XCTAssertEqual(lines, ["café", "résumé"])
    }

    // MARK: init error path.

    func testInitThrowsForMissingFile() {
        let missing = tempDir.appendingPathComponent("does-not-exist.log")
        XCTAssertThrowsError(try LineReader(url: missing))
    }
}
