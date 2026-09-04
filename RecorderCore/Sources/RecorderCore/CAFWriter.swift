import AVFoundation
import Foundation

/// Streams one track to a CAF file as LPCM 16-bit / 48 kHz.
///
/// CAF is written incrementally, so a crash or `kill -9` still leaves a playable
/// file — the recovered duration is simply whatever reached the disk (spec §4).
/// QuickTime reads CAF/LPCM without any extra codec (acceptance criterion 6).
///
/// The file is closed when the writer is released.
public final class CAFWriter {

    public static let sampleRate: Double = 48000
    /// Silence is emitted in chunks so a ten-minute gap never allocates a huge buffer.
    private static let silenceChunkFrames = 48000

    /// Frames written so far — audio plus silence.
    public private(set) var framesWritten: Int = 0

    public let url: URL
    private let file: AVAudioFile
    private let processingFormat: AVAudioFormat

    /// - Parameters:
    ///   - url: destination, expected to end in `.caf`.
    ///   - channels: 1 for the mic track (local), 2 for the system track (remote).
    public init(url: URL, channels: AVAudioChannelCount) throws {
        self.url = url

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        // Written as float32 and stored as int16: AVAudioFile converts on write,
        // which keeps the IO callback free of manual sample conversion.
        self.file = try AVAudioFile(forWriting: url,
                                    settings: settings,
                                    commonFormat: .pcmFormatFloat32,
                                    interleaved: false)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate,
                                         channels: channels) else {
            throw CAFWriterError.unsupportedFormat(channels: channels)
        }
        self.processingFormat = format
    }

    /// Append captured audio.
    public func write(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength > 0 else { return }
        try file.write(from: buffer)
        framesWritten += Int(buffer.frameLength)
    }

    /// Append `frames` of digital silence.
    ///
    /// This is what keeps the timeline honest: a gap in the stream is *written*,
    /// never skipped, so `framesWritten == duration × 48000` always holds.
    public func writeSilence(frames: Int) throws {
        guard frames > 0 else { return }

        var remaining = frames
        while remaining > 0 {
            let chunk = min(remaining, Self.silenceChunkFrames)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat,
                                                frameCapacity: AVAudioFrameCount(chunk)) else {
                throw CAFWriterError.bufferAllocationFailed(frames: chunk)
            }
            buffer.frameLength = AVAudioFrameCount(chunk)
            for channel in 0..<Int(processingFormat.channelCount) {
                memset(buffer.floatChannelData![channel], 0, chunk * MemoryLayout<Float>.size)
            }
            try file.write(from: buffer)
            remaining -= chunk
        }
        framesWritten += frames
    }
}

public enum CAFWriterError: Error, CustomStringConvertible {
    case unsupportedFormat(channels: AVAudioChannelCount)
    case bufferAllocationFailed(frames: Int)

    public var description: String {
        switch self {
        case .unsupportedFormat(let channels):
            return "Непідтримуваний формат: \(channels) канал(ів)"
        case .bufferAllocationFailed(let frames):
            return "Не вдалося виділити буфер на \(frames) семплів"
        }
    }
}
