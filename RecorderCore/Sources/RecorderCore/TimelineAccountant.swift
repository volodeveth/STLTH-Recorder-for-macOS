import Foundation

/// Keeps a recorded track aligned with wall-clock time.
///
/// The audio stream can stall — a device change, a CoreAudio hiccup, system sleep.
/// If we simply appended every buffer we received, the file would get *shorter* than
/// the session and the two tracks would slide apart. Instead every buffer is checked
/// against the timestamp we expected it at, and any gap is filled with silence.
///
/// Invariant (spec §3): `totalFrames == duration × sampleRate` for every track.
/// Silence is written, never cut out.
public struct TimelineAccountant {

    /// Frames accounted for so far — written audio plus inserted silence.
    public private(set) var totalFrames: Int = 0

    private let sampleRate: Double
    /// Timestamp at which the next buffer is expected to start, in seconds.
    private var expectedNext: Double?
    /// Scheduling noise below this is normal IO jitter, not a real gap.
    private let jitterTolerance = 0.005 // 5 ms

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// Anchor the track to the moment the session started.
    ///
    /// Without this the timeline only begins at the first buffer, and everything
    /// before it is lost rather than padded — which matters because a process tap
    /// delivers nothing at all until some process starts playing.
    public mutating func start(at timestamp: Double) {
        expectedNext = timestamp
    }

    /// Frames of silence needed to carry the track up to `timestamp`.
    ///
    /// Called when the session stops: the stream may have gone quiet long before, and
    /// the file still has to be as long as the session. Returns 0 when the track
    /// already reaches that far.
    public mutating func frames(toReach timestamp: Double) -> Int {
        guard let expected = expectedNext, timestamp > expected else { return 0 }
        let pad = Int(((timestamp - expected) * sampleRate).rounded())
        guard pad > 0 else { return 0 }
        expectedNext = timestamp
        totalFrames += pad
        return pad
    }

    /// Frames of silence to insert before a buffer that starts at `timestamp`.
    ///
    /// - Parameters:
    ///   - timestamp: buffer start time in seconds, on a monotonic clock.
    ///   - frameCount: number of frames in the buffer.
    /// - Returns: how many silent frames to write before it (0 when contiguous).
    public mutating func frames(toInsertBefore timestamp: Double, frameCount: Int) -> Int {
        var pad = 0
        if let expected = expectedNext, timestamp - expected > jitterTolerance {
            pad = Int(((timestamp - expected) * sampleRate).rounded())
        }
        expectedNext = timestamp + Double(frameCount) / sampleRate
        totalFrames += pad + frameCount
        return pad
    }
}
