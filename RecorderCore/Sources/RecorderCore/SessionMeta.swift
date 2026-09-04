import Foundation

/// Result of one capture run, handed from `AudioEngine` to `SessionStore`.
/// How the two tracks were captured.
public enum CaptureMode: String, Codable, Sendable {
    /// Preferred: mic and tap share one aggregate device, hence one clock — channel
    /// synchronisation holds by construction.
    case singleAggregate = "single-aggregate"
    /// Fallback: the aggregate refused to run with this microphone (some virtual and
    /// exotic input drivers do), so the mic is captured on its own engine. Both tracks
    /// are still padded to wall-clock length, but they run on two clocks — alignment
    /// then rests on the timeline invariant rather than on shared hardware timing.
    case splitClock = "split-clock"
    /// No audio input exists on this machine; mic.caf is written as silence.
    case systemOnly = "system-only"
}

public struct RecordingResult: Equatable, Sendable {
    public let micURL: URL
    public let systemURL: URL
    public let durationMs: Int
    public let inputDeviceName: String
    public let outputDeviceName: String
    public let captureMode: CaptureMode
    /// Devices the user switched to mid-session, in the order it happened.
    public let deviceChanges: [SessionMeta.DeviceChange]
    /// Whether the system track carried real audio — the only reliable evidence that
    /// the system-audio permission is actually in force.
    public let systemAudioDetected: Bool

    public init(micURL: URL,
                systemURL: URL,
                durationMs: Int,
                inputDeviceName: String,
                outputDeviceName: String,
                captureMode: CaptureMode = .singleAggregate,
                deviceChanges: [SessionMeta.DeviceChange] = [],
                systemAudioDetected: Bool = true) {
        self.micURL = micURL
        self.systemURL = systemURL
        self.durationMs = durationMs
        self.inputDeviceName = inputDeviceName
        self.outputDeviceName = outputDeviceName
        self.captureMode = captureMode
        self.deviceChanges = deviceChanges
        self.systemAudioDetected = systemAudioDetected
    }
}

/// `meta.json` — the session's record on disk. Shape follows spec §2, which in turn
/// extends the example given in the ТЗ (F-3).
public struct SessionMeta: Codable, Equatable, Sendable {

    public enum Status: String, Codable, Sendable {
        case recording
        case completed
        case interrupted
    }

    public struct Consent: Codable, Equatable, Sendable {
        public var confirmed: Bool
        public var at: Date

        public init(confirmed: Bool, at: Date) {
            self.confirmed = confirmed
            self.at = at
        }
    }

    public struct Track: Codable, Equatable, Sendable {
        public var channel: String   // "mic" | "system"
        public var speaker: String   // "local" | "remote"; sessions from 1.2.0 carry "advisor" | "client"
        public var file: String
        public var format: String
        public var sampleRate: Int
        public var channels: Int

        public init(channel: String, speaker: String, file: String,
                    format: String, sampleRate: Int, channels: Int) {
            self.channel = channel
            self.speaker = speaker
            self.file = file
            self.format = format
            self.sampleRate = sampleRate
            self.channels = channels
        }

        public static let mic = Track(channel: "mic", speaker: "local", file: "mic.caf",
                                      format: "caf/lpcm", sampleRate: 48000, channels: 1)
        public static let system = Track(channel: "system", speaker: "remote", file: "system.caf",
                                         format: "caf/lpcm", sampleRate: 48000, channels: 2)
    }

    public struct Devices: Codable, Equatable, Sendable {
        public var input: String
        public var output: String

        public init(input: String, output: String) {
            self.input = input
            self.output = output
        }
    }

    public struct DeviceChange: Codable, Equatable, Sendable {
        public var at: Date
        public var input: String?
        public var output: String?

        public init(at: Date, input: String? = nil, output: String? = nil) {
            self.at = at
            self.input = input
            self.output = output
        }
    }

    public var sessionId: UUID
    public var startedAt: Date
    public var durationMs: Int
    public var status: Status
    public var consent: Consent
    public var tracks: [Track]
    public var devices: Devices
    public var deviceChanges: [DeviceChange]
    public var appVersion: String
    public var osVersion: String
    /// How capture was wired up for this session — diagnostics for the drift report.
    public var captureMode: CaptureMode?
    /// Name of the derived listening mixdown, when one has been produced.
    ///
    /// Optional on purpose: sessions recorded before mixdowns existed decode without
    /// it, and the analytics pipeline reads `meta.json` rather than listing the
    /// directory. The two source tracks remain the record; this is a convenience.
    public var mixFile: String?
    /// When the source tracks were deleted after transcription, if they were.
    ///
    /// Optional for the same reason as `mixFile`: sessions recorded before the option
    /// existed decode without it. Set only when something was actually freed, so a
    /// session without audio is never mistaken for a damaged one — the difference
    /// between "removed on purpose" and "vanished" is exactly what this records.
    public var audioRemovedAt: Date?

    public init(sessionId: UUID,
                startedAt: Date,
                durationMs: Int,
                status: Status,
                consent: Consent,
                tracks: [Track],
                devices: Devices,
                deviceChanges: [DeviceChange],
                appVersion: String,
                osVersion: String,
                captureMode: CaptureMode? = nil,
                mixFile: String? = nil,
                audioRemovedAt: Date? = nil) {
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.status = status
        self.consent = consent
        self.tracks = tracks
        self.devices = devices
        self.deviceChanges = deviceChanges
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.captureMode = captureMode
        self.mixFile = mixFile
        self.audioRemovedAt = audioRemovedAt
    }
}

// MARK: - Serialisation

public extension SessionMeta {

    /// ISO 8601 with the local UTC offset, e.g. `2026-08-12T14:00:03.412+03:00`
    /// — offset-bearing as in the spec, not a Z-normalised timestamp.
    ///
    /// Fractional seconds are included on purpose: with whole-second precision two
    /// sessions started within the same second sort non-deterministically in
    /// "Останні записи", and a recovered duration loses up to a second.
    static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(SessionMeta.dateFormatter.string(from: date))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            guard let date = SessionMeta.dateFormatter.date(from: string) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Некоректна дата: \(string)")
                )
            }
            return date
        }
        return decoder
    }()

    static func load(from url: URL) throws -> SessionMeta {
        try decoder.decode(SessionMeta.self, from: Data(contentsOf: url))
    }

    /// Write atomically — a crash mid-write must never leave a truncated meta.json.
    func write(to url: URL) throws {
        let data = try SessionMeta.encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
