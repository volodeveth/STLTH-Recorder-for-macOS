import AVFoundation
import Foundation
import Testing
@testable import RecorderCore

/// A session killed mid-write leaves `data` chunk size = -1 ("unknown"), because the
/// size is only patched when AVAudioFile closes. Apple's own stack tolerates that,
/// but libsndfile/ffmpeg call the file malformed — and the recording is meant to feed
/// an analytics pipeline, so it has to be readable by ordinary tools too.
@Suite("CAF repair")
struct CAFRepairTests {

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stlth-repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Rewrite the `data` chunk size back to -1, reproducing what a crash leaves behind.
    private func breakDataChunkSize(at url: URL) throws {
        var bytes = try Data(contentsOf: url)
        let marker = Array("data".utf8)
        guard let range = bytes.firstRange(of: marker) else {
            Issue.record("не знайдено data chunk")
            return
        }
        let sizeOffset = range.lowerBound + 4
        for index in 0..<8 {
            bytes[sizeOffset + index] = 0xFF
        }
        try bytes.write(to: url)
    }

    private func dataChunkSize(at url: URL) throws -> Int64? {
        let bytes = try Data(contentsOf: url)
        let marker = Array("data".utf8)
        guard let range = bytes.firstRange(of: marker) else { return nil }
        let sizeOffset = range.lowerBound + 4
        var value: Int64 = 0
        for index in 0..<8 {
            value = (value << 8) | Int64(bytes[sizeOffset + index]) // CAF is big-endian
        }
        return value
    }

    @Test("A crashed session gets its data chunk size repaired")
    func repairsUnknownDataChunkSize() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(root: root)
        let handle = try store.begin(consentAt: Date())

        var writer: CAFWriter? = try CAFWriter(url: handle.dir.appendingPathComponent("mic.caf"), channels: 1)
        try writer?.writeSilence(frames: 48000)
        writer = nil

        let micURL = handle.dir.appendingPathComponent("mic.caf")
        try breakDataChunkSize(at: micURL)
        #expect(try dataChunkSize(at: micURL) == -1, "фікстура має містити -1")

        store.recoverInterrupted()

        let repaired = try #require(try dataChunkSize(at: micURL))
        #expect(repaired > 0, "розмір data chunk має бути реальним, а не -1")

        // And the audio itself must survive the repair untouched.
        let file = try AVAudioFile(forReading: micURL)
        #expect(file.length == 48000)
    }

    @Test("A cleanly closed file is left alone")
    func healthyFileUntouched() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(root: root)
        let handle = try store.begin(consentAt: Date())

        var writer: CAFWriter? = try CAFWriter(url: handle.dir.appendingPathComponent("mic.caf"), channels: 1)
        try writer?.writeSilence(frames: 4800)
        writer = nil

        let micURL = handle.dir.appendingPathComponent("mic.caf")
        let before = try Data(contentsOf: micURL)

        store.recoverInterrupted()

        let after = try Data(contentsOf: micURL)
        #expect(before == after)
    }
}

private extension Data {
    func firstRange(of pattern: [UInt8]) -> Range<Int>? {
        guard !pattern.isEmpty, count >= pattern.count else { return nil }
        for start in 0...(count - pattern.count) where Array(self[start..<start + pattern.count]) == pattern {
            return start..<(start + pattern.count)
        }
        return nil
    }
}
