import AVFoundation
import Foundation
import Testing
@testable import RecorderCore

/// The mixdown is a **derived** file: something to listen to, never the source of
/// truth. `mic.caf` and `system.caf` stay untouched and remain what the analytics
/// pipeline consumes — so these tests care that the mix is faithful, not that it is
/// authoritative.
@Suite("SessionMixer")
struct SessionMixerTests {

    // MARK: - Fixtures

    private func makeSession() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stlth-mix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A tone of `frames` samples at `amplitude`, written as one track.
    private func writeTrack(at url: URL,
                            channels: AVAudioChannelCount,
                            frames: Int,
                            amplitude: Float,
                            frequency: Double = 440) throws {
        let writer = try CAFWriter(url: url, channels: channels)
        try writer.write(tone(frames: frames, channels: channels,
                              amplitude: amplitude, frequency: frequency))
    }

    private func tone(frames: Int,
                      channels: AVAudioChannelCount,
                      amplitude: Float,
                      frequency: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(channels) {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<frames {
                let phase = 2 * Double.pi * frequency * Double(frame) / 48000
                samples[frame] = amplitude * Float(sin(phase))
            }
        }
        return buffer
    }

    /// Per-channel peak and RMS of the mixed file, so assertions can talk about
    /// "what landed left" and "what landed right" separately.
    private func analyse(_ url: URL) throws -> (frames: Int, leftPeak: Float, rightPeak: Float,
                                                leftRMS: Float, rightRMS: Float) {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: file.fileFormat.sampleRate,
                                   channels: file.fileFormat.channelCount)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)

        var peaks: [Float] = [0, 0]
        var sums: [Double] = [0, 0]
        let frames = Int(buffer.frameLength)
        for channel in 0..<min(2, Int(format.channelCount)) {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<frames {
                let value = samples[frame]
                peaks[channel] = max(peaks[channel], abs(value))
                sums[channel] += Double(value * value)
            }
        }
        let rms = sums.map { Float(($0 / Double(max(frames, 1))).squareRoot()) }
        return (frames, peaks[0], peaks[1], rms[0], rms[1])
    }

    // MARK: - Tests

    @Test("The mixdown is as long as the sources")
    func lengthMatchesSources() throws {
        let dir = try makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let frames = 48000 * 2 // 2 s
        try writeTrack(at: dir.appendingPathComponent("mic.caf"),
                       channels: 1, frames: frames, amplitude: 0.4)
        try writeTrack(at: dir.appendingPathComponent("system.caf"),
                       channels: 2, frames: frames, amplitude: 0.4)

        let mixed = try SessionMixer.mix(sessionDir: dir)
        let result = try analyse(mixed)

        // Not sample-exact on purpose: AAC carries priming and padding frames, so a
        // decoded file is a thousand-odd frames longer than what went in. Demanding
        // exactness here would only be achievable with LPCM, which we deliberately
        // did not choose.
        let tolerance = Int(0.05 * 48000)
        #expect(abs(result.frames - frames) <= tolerance)
    }

    @Test("Padded silence stays where it was, and is not squeezed out")
    func silenceIsPreserved() throws {
        let dir = try makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1 s tone, 2 s silence, 1 s tone — the shape a mute leaves behind.
        for (name, channels) in [("mic.caf", AVAudioChannelCount(1)),
                                 ("system.caf", AVAudioChannelCount(2))] {
            let writer = try CAFWriter(url: dir.appendingPathComponent(name), channels: channels)
            try writer.write(tone(frames: 48000, channels: channels, amplitude: 0.4, frequency: 440))
            try writer.writeSilence(frames: 48000 * 2)
            try writer.write(tone(frames: 48000, channels: channels, amplitude: 0.4, frequency: 440))
        }

        let mixed = try SessionMixer.mix(sessionDir: dir)
        let file = try AVAudioFile(forReading: mixed)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)

        // Sample the middle of the gap: if silence had been dropped, audio would sit
        // here and everything after it would have moved earlier.
        let samples = buffer.floatChannelData![0]
        var gapPeak: Float = 0
        for frame in (48000 * 2)..<(48000 * 5 / 2) where frame < Int(buffer.frameLength) {
            gapPeak = max(gapPeak, abs(samples[frame]))
        }
        #expect(gapPeak < 0.02)
        #expect(abs(Int(buffer.frameLength) - 48000 * 4) <= Int(0.05 * 48000))
    }

    @Test("The local voice lands left and the remote one lands right")
    func voicesAreSeparatedAcrossChannels() throws {
        let dir = try makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Only the local side speaks.
        try writeTrack(at: dir.appendingPathComponent("mic.caf"),
                       channels: 1, frames: 48000, amplitude: 0.6)
        let silent = try CAFWriter(url: dir.appendingPathComponent("system.caf"), channels: 2)
        try silent.writeSilence(frames: 48000)

        let localOnly = try analyse(try SessionMixer.mix(sessionDir: dir))
        #expect(localOnly.leftRMS > localOnly.rightRMS * 3)

        // And now only the remote side.
        let other = try makeSession()
        defer { try? FileManager.default.removeItem(at: other) }
        let quiet = try CAFWriter(url: other.appendingPathComponent("mic.caf"), channels: 1)
        try quiet.writeSilence(frames: 48000)
        try writeTrack(at: other.appendingPathComponent("system.caf"),
                       channels: 2, frames: 48000, amplitude: 0.6)

        let remoteOnly = try analyse(try SessionMixer.mix(sessionDir: other))
        #expect(remoteOnly.rightRMS > remoteOnly.leftRMS * 3)
    }

    @Test("Two loud sources do not clip")
    func loudSourcesDoNotClip() throws {
        let dir = try makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Both at full scale at once — louder than any real meeting.
        try writeTrack(at: dir.appendingPathComponent("mic.caf"),
                       channels: 1, frames: 48000, amplitude: 1.0, frequency: 440)
        try writeTrack(at: dir.appendingPathComponent("system.caf"),
                       channels: 2, frames: 48000, amplitude: 1.0, frequency: 660)

        let result = try analyse(try SessionMixer.mix(sessionDir: dir))
        // AAC overshoots between samples on decode, so the bar is "no wrap-around",
        // not "never touches 1.0".
        #expect(result.leftPeak <= 1.0)
        #expect(result.rightPeak <= 1.0)
    }

    @Test("Mixing twice is safe and leaves one file")
    func mixingIsIdempotent() throws {
        let dir = try makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeTrack(at: dir.appendingPathComponent("mic.caf"),
                       channels: 1, frames: 24000, amplitude: 0.3)
        try writeTrack(at: dir.appendingPathComponent("system.caf"),
                       channels: 2, frames: 24000, amplitude: 0.3)

        let first = try SessionMixer.mix(sessionDir: dir)
        let second = try SessionMixer.mix(sessionDir: dir)

        #expect(first == second)
        #expect(SessionMixer.mixExists(in: dir))
        let result = try analyse(second)
        #expect(result.frames > 0)
    }

    @Test("A session missing a track fails clearly instead of writing half a mix")
    func missingTrackIsReported() throws {
        let dir = try makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeTrack(at: dir.appendingPathComponent("mic.caf"),
                       channels: 1, frames: 4800, amplitude: 0.3)

        #expect(throws: SessionMixer.MixerError.self) {
            try SessionMixer.mix(sessionDir: dir)
        }
        #expect(!SessionMixer.mixExists(in: dir))
    }

    @Test("A CAF left unrepaired by a crash is healed before mixing")
    func crashedSessionIsRepairedFirst() throws {
        let dir = try makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeTrack(at: dir.appendingPathComponent("mic.caf"),
                       channels: 1, frames: 48000, amplitude: 0.4)
        try writeTrack(at: dir.appendingPathComponent("system.caf"),
                       channels: 2, frames: 48000, amplitude: 0.4)

        // Put the mic track back into the state `kill -9` leaves it: data chunk size
        // of -1. Apple's readers tolerate it; libsndfile and ffmpeg do not, and the
        // mixdown must not inherit that.
        let micURL = dir.appendingPathComponent("mic.caf")
        try breakDataChunkSize(at: micURL)
        #expect(CAFRepair.repairIfNeeded(at: micURL) == true)
        try breakDataChunkSize(at: micURL)

        let mixed = try SessionMixer.mix(sessionDir: dir)
        #expect(try analyse(mixed).frames > 0)
        // mix() must have repaired it on the way through.
        #expect(CAFRepair.repairIfNeeded(at: micURL) == false)
    }

    /// Rewrite the `data` chunk size as -1, the way an interrupted writer leaves it.
    private func breakDataChunkSize(at url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        var offset: UInt64 = 8
        while offset + 12 <= size {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 12), header.count == 12 else { return }
            let type = String(decoding: header[header.startIndex..<header.startIndex + 4], as: UTF8.self)
            let chunkSize = header[(header.startIndex + 4)...].reduce(Int64(0)) { ($0 << 8) | Int64($1) }
            if type == "data" {
                var minusOne = Int64(-1).bigEndian
                let bytes = withUnsafeBytes(of: &minusOne) { Data($0) }
                try handle.seek(toOffset: offset + 4)
                try handle.write(contentsOf: bytes)
                return
            }
            guard chunkSize > 0 else { return }
            offset += 12 + UInt64(chunkSize)
        }
    }

    @Test("meta.json written before mixdowns existed still decodes")
    func oldMetaDecodesWithoutMixField() throws {
        // Byte-for-byte the shape sessions were written in before `mixFile` existed.
        let json = """
        {
          "appVersion" : "1.0.0",
          "consent" : { "at" : "2026-08-08T07:26:41.057-07:00", "confirmed" : true },
          "deviceChanges" : [],
          "devices" : { "input" : "BlackHole 2ch", "output" : "Mac mini Speakers" },
          "durationMs" : 600095,
          "osVersion" : "26.6.0",
          "sessionId" : "05271924-F0E4-4591-A2BC-7AFEF3EA0866",
          "startedAt" : "2026-08-08T07:26:41.057-07:00",
          "status" : "completed",
          "tracks" : []
        }
        """
        let meta = try SessionMeta.decoder.decode(SessionMeta.self, from: Data(json.utf8))
        #expect(meta.mixFile == nil)
        #expect(meta.durationMs == 600095)
    }
}
