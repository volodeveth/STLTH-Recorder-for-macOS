import AVFoundation
import Foundation
import OSLog

/// Folds a session's two tracks into one file you can simply listen to.
///
/// **This file is derived, never authoritative.** `mic.caf` and `system.caf` stay
/// untouched and remain what the analytics pipeline consumes; `session.m4a` exists so
/// a human can hear the conversation as a conversation. If mixing fails, the session
/// is still complete and still correct.
///
/// **No alignment is attempted, and none is needed.** Both tracks are written by the
/// same IO callback of the same aggregate device, and every gap is already filled
/// with silence by `TimelineAccountant` (ENGINEERING_NOTES §3). They are equal in
/// length and aligned sample-for-sample, so the mix is a plain sum from frame zero.
/// Searching for an offset here would be looking for a problem that was designed out.
public enum SessionMixer {

    private static let logger = Logger(subsystem: "ua.stlth.STLTHRecorder", category: "SessionMixer")

    public static let fileName = "session.m4a"

    public enum MixerError: LocalizedError, Equatable {
        case missingTrack(String)
        case unreadableTrack(String)
        case notEnoughSpace(needBytes: Int64)
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missingTrack(let name):
                return "У теці сесії немає \(name)"
            case .unreadableTrack(let name):
                return "Не вдалося прочитати \(name)"
            case .notEnoughSpace(let bytes):
                return "Замало місця для зведеного файлу (потрібно ≈ \(bytes / 1_048_576) МБ)"
            case .writeFailed(let details):
                return "Не вдалося записати зведений файл: \(details)"
            }
        }
    }

    // MARK: - Mix shape

    /// How far each voice sits from the centre.
    ///
    /// Not hard-panned. Full separation is the most legible arrangement — you hear
    /// instantly who interrupted whom — but an hour of it is tiring, and on a single
    /// speaker one participant would vanish entirely. At 85/15 the separation is still
    /// obvious while both voices survive a mono downmix.
    static let dominant: Float = 0.85
    static let bleed: Float = 0.15

    /// Headroom before encoding.
    ///
    /// Not because the two tracks sum to more than one — with this panning they only
    /// partly overlap — but because **AAC overshoots between samples on decode**. A
    /// mix that peaks at exactly 1.0 comes back above it and wraps around.
    static let headroom: Float = 0.8

    /// One output frame from one frame of each source. Pure, so the shape of the mix
    /// is testable without touching a file.
    static func frame(advisor: Float, client: Float) -> (left: Float, right: Float) {
        let left = advisor * dominant + client * bleed
        let right = client * dominant + advisor * bleed
        return (clamp(left * headroom), clamp(right * headroom))
    }

    private static func clamp(_ value: Float) -> Float {
        min(max(value, -1), 1)
    }

    // MARK: - API

    public static func mixURL(in sessionDir: URL) -> URL {
        sessionDir.appendingPathComponent(fileName)
    }

    public static func mixExists(in sessionDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: mixURL(in: sessionDir).path)
    }

    /// Produce `session.m4a` beside the tracks.
    ///
    /// - Parameter force: rebuild even if a mix is already there.
    /// - Returns: the mixdown's URL.
    @discardableResult
    public static func mix(sessionDir: URL, force: Bool = false) throws -> URL {
        let target = mixURL(in: sessionDir)
        if !force, FileManager.default.fileExists(atPath: target.path) {
            return target
        }

        let micURL = sessionDir.appendingPathComponent("mic.caf")
        let systemURL = sessionDir.appendingPathComponent("system.caf")
        for (url, name) in [(micURL, "mic.caf"), (systemURL, "system.caf")] {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw MixerError.missingTrack(name)
            }
            // A session the app was killed during still carries a data chunk of size
            // -1. Apple's readers tolerate it, so the mix would appear to work while
            // silently truncating (ENGINEERING_NOTES §3a) — repair first, always.
            CAFRepair.repairIfNeeded(at: url)
        }

        guard let mic = try? AVAudioFile(forReading: micURL) else {
            throw MixerError.unreadableTrack("mic.caf")
        }
        guard let system = try? AVAudioFile(forReading: systemURL) else {
            throw MixerError.unreadableTrack("system.caf")
        }

        let frames = max(mic.length, system.length)
        try checkSpace(for: frames, at: sessionDir)

        let sampleRate = mic.fileFormat.sampleRate
        let temporary = sessionDir.appendingPathComponent("\(fileName).part")
        try? FileManager.default.removeItem(at: temporary)

        do {
            try render(mic: mic, system: system, frames: frames,
                       sampleRate: sampleRate, to: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw MixerError.writeFailed(error.localizedDescription)
        }

        // Swapped into place only once it is whole: a half-written mix must never look
        // like a finished one to the menu.
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: temporary, to: target)
        } catch {
            throw MixerError.writeFailed(error.localizedDescription)
        }

        logger.info("""
            Mixdown written for \(sessionDir.lastPathComponent, privacy: .public): \
            \(frames) frames
            """)
        return target
    }

    // MARK: - Internals

    private static func render(mic: AVAudioFile,
                               system: AVAudioFile,
                               frames: AVAudioFramePosition,
                               sampleRate: Double,
                               to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 96_000,
        ]
        let output = try AVAudioFile(forWriting: url,
                                     settings: settings,
                                     commonFormat: .pcmFormatFloat32,
                                     interleaved: false)

        let chunk: AVAudioFrameCount = 48_000
        let micFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                      channels: mic.processingFormat.channelCount)!
        let systemFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: system.processingFormat.channelCount)!
        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

        guard let micBuffer = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: chunk),
              let systemBuffer = AVAudioPCMBuffer(pcmFormat: systemFormat, frameCapacity: chunk),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: chunk) else {
            throw MixerError.writeFailed("не вдалося виділити буфери")
        }

        var written: AVAudioFramePosition = 0
        while written < frames {
            let count = AVAudioFrameCount(min(AVAudioFramePosition(chunk), frames - written))

            // A track that ended earlier simply contributes silence for the rest —
            // the mix is as long as the session, not as the shorter file.
            try read(mic, into: micBuffer, count: count)
            try read(system, into: systemBuffer, count: count)

            outBuffer.frameLength = count
            let left = outBuffer.floatChannelData![0]
            let right = outBuffer.floatChannelData![1]
            let advisor = micBuffer.floatChannelData![0]
            let clientL = systemBuffer.floatChannelData![0]
            let clientR = systemFormat.channelCount > 1
                ? systemBuffer.floatChannelData![1]
                : systemBuffer.floatChannelData![0]

            for index in 0..<Int(count) {
                // The client's track is stereo but carries one voice; fold it to mono
                // before panning, or the two sides would arrive at different levels.
                let client = (clientL[index] + clientR[index]) * 0.5
                let mixed = frame(advisor: advisor[index], client: client)
                left[index] = mixed.left
                right[index] = mixed.right
            }

            try output.write(from: outBuffer)
            written += AVAudioFramePosition(count)
        }
    }

    /// Read `count` frames, zero-filling whatever the file no longer has.
    private static func read(_ file: AVAudioFile,
                             into buffer: AVAudioPCMBuffer,
                             count: AVAudioFrameCount) throws {
        buffer.frameLength = count
        for channel in 0..<Int(buffer.format.channelCount) {
            memset(buffer.floatChannelData![channel], 0, Int(count) * MemoryLayout<Float>.size)
        }

        let available = file.length - file.framePosition
        guard available > 0 else { return }

        let toRead = AVAudioFrameCount(min(AVAudioFramePosition(count), available))
        let scratch = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: toRead)!
        try file.read(into: scratch, frameCount: toRead)

        for channel in 0..<Int(buffer.format.channelCount) {
            memcpy(buffer.floatChannelData![channel],
                   scratch.floatChannelData![channel],
                   Int(scratch.frameLength) * MemoryLayout<Float>.size)
        }
        buffer.frameLength = count
    }

    /// AAC at 96 kbps is about 12 KB per second; ask for twice that before starting.
    private static func checkSpace(for frames: AVAudioFramePosition, at dir: URL) throws {
        let seconds = Double(frames) / CAFWriter.sampleRate
        let estimate = Int64(seconds * 12_000)
        let need = max(estimate * 2, DiskGuard.criticalThreshold)
        guard DiskGuard.freeBytes(at: dir) > need else {
            throw MixerError.notEnoughSpace(needBytes: need)
        }
    }
}
