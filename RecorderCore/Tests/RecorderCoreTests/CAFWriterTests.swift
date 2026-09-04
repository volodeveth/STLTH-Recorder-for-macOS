import AVFoundation
import Foundation
import Testing
@testable import RecorderCore

@Suite("CAFWriter")
struct CAFWriterTests {

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stlth-caf-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A buffer of a quiet sine wave in the writer's processing format.
    private func sineBuffer(frames: AVAudioFrameCount, channels: AVAudioChannelCount) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: CAFWriter.sampleRate,
                                   channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let data = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) {
                data[frame] = 0.5 * sin(2.0 * .pi * 440.0 * Float(frame) / Float(CAFWriter.sampleRate))
            }
        }
        return buffer
    }

    @Test("Audio plus silence produce exactly the expected number of frames")
    func writesAudioAndSilence() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mic.caf")

        var writer: CAFWriter? = try CAFWriter(url: url, channels: 1)
        try writer?.write(sineBuffer(frames: 480, channels: 1))
        try writer?.writeSilence(frames: 480)
        writer = nil // closing the file is what flushes it

        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 960)
        #expect(file.fileFormat.sampleRate == 48000)
        #expect(file.fileFormat.channelCount == 1)
    }

    @Test("The stereo system track is written as two channels")
    func writesStereo() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("system.caf")

        var writer: CAFWriter? = try CAFWriter(url: url, channels: 2)
        try writer?.write(sineBuffer(frames: 1024, channels: 2))
        writer = nil

        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 1024)
        #expect(file.fileFormat.channelCount == 2)
    }

    @Test("Files are LPCM 16-bit, readable by a plain player (acceptance criterion 6)")
    func writesSixteenBitLPCM() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mic.caf")

        var writer: CAFWriter? = try CAFWriter(url: url, channels: 1)
        try writer?.write(sineBuffer(frames: 480, channels: 1))
        writer = nil

        let file = try AVAudioFile(forReading: url)
        let description = file.fileFormat.streamDescription.pointee
        #expect(description.mFormatID == kAudioFormatLinearPCM)
        #expect(description.mBitsPerChannel == 16)
    }

    @Test("Long silence is written in full, not truncated (acceptance criterion 4)")
    func writesLongSilenceInFull() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mic.caf")

        // 30 seconds of silence — more than one internal chunk, so chunking is covered.
        let frames = 30 * Int(CAFWriter.sampleRate)
        var writer: CAFWriter? = try CAFWriter(url: url, channels: 1)
        try writer?.writeSilence(frames: frames)
        writer = nil

        let file = try AVAudioFile(forReading: url)
        #expect(file.length == AVAudioFramePosition(frames))
    }

    @Test("The writer reports how many frames it has written")
    func tracksWrittenFrames() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mic.caf")

        let writer = try CAFWriter(url: url, channels: 1)
        try writer.write(sineBuffer(frames: 480, channels: 1))
        try writer.writeSilence(frames: 120)
        #expect(writer.framesWritten == 600)
    }

    @Test("Writing zero frames of silence is a no-op")
    func zeroSilenceIsNoop() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mic.caf")

        let writer = try CAFWriter(url: url, channels: 1)
        try writer.writeSilence(frames: 0)
        try writer.writeSilence(frames: -5)
        #expect(writer.framesWritten == 0)
    }
}
