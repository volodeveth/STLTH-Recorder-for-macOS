import Foundation

/// Watches free disk space so a long meeting cannot silently fill the volume.
///
/// Thresholds come from spec §4: warn under ~1 GB before starting, stop cleanly
/// under 200 MB while recording — a controlled stop keeps the audio playable,
/// an out-of-space write does not.
public enum DiskGuard {

    public enum Level: Equatable, Sendable {
        case ok
        case low       // warn before starting
        case critical  // stop an ongoing recording
    }

    /// Below this a running session is stopped: 200 MB ≈ 11 minutes of both tracks.
    public static let criticalThreshold: Int64 = 200 * 1024 * 1024
    /// Below this the consent sheet shows a warning: 1 GB ≈ 58 minutes.
    public static let lowThreshold: Int64 = 1024 * 1024 * 1024

    /// 48 kHz × 16 bit × (1 mono + 2 stereo) channels.
    public static let bytesPerSecond: Int64 = 48000 * 2 * 3

    /// Free bytes on the volume holding `url`; 0 only when the volume itself cannot
    /// be reached.
    ///
    /// Both APIs below answer for *existing* paths only. On a fresh install the
    /// sessions folder has never been created, so both failed, this returned 0, and
    /// the consent sheet declared the disk full on a Mac with 419 GB free — blocking
    /// the very first recording every new user would try. The volume is the same
    /// whether or not the leaf exists, so the query walks up to the nearest ancestor
    /// that does.
    public static func freeBytes(at url: URL) -> Int64 {
        var candidate = url.standardizedFileURL
        while true {
            if let bytes = freeBytesForExistingPath(candidate), bytes > 0 {
                return bytes
            }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            guard parent.path != candidate.path else { return 0 }
            candidate = parent
        }
    }

    private static func freeBytesForExistingPath(_ url: URL) -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // A zero from the modern key means "no answer", not "no space": it reports
        // capacity *for important usage*, which the system sometimes declines to
        // estimate. Returning that 0 as a measurement is how a Mac with 412 GB free
        // was declared full a second time — so a 0 here falls through to the classic
        // attribute instead of being believed.
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage,
           capacity > 0 {
            return capacity
        }
        // Fall back to the classic attribute — the modern key is not answered on
        // every volume type.
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
              let free = attributes[.systemFreeSize] as? NSNumber else {
            return nil
        }
        return free.int64Value
    }

    public static func level(forFreeBytes bytes: Int64) -> Level {
        if bytes < criticalThreshold { return .critical }
        if bytes < lowThreshold { return .low }
        return .ok
    }

    public static func level(at url: URL) -> Level {
        level(forFreeBytes: freeBytes(at: url))
    }

    /// How many more minutes of recording fit into `freeBytes`.
    public static func estimatedMinutesRemaining(freeBytes: Int64) -> Int {
        guard freeBytes > 0 else { return 0 }
        return Int(freeBytes / bytesPerSecond / 60)
    }
}
