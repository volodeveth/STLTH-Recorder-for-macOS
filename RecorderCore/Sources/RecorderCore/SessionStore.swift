import AVFoundation
import Foundation

/// Handle to a session that is currently being recorded.
public struct SessionHandle: Equatable, Sendable {
    public let id: UUID
    public let dir: URL

    public init(id: UUID, dir: URL) {
        self.id = id
        self.dir = dir
    }
}

/// Owns the on-disk layout of recordings:
/// `~/Library/Application Support/STLTHRecorder/Sessions/<UUID>/{mic.caf,system.caf,meta.json}`
///
/// Nothing ever leaves this directory — the app makes no network requests (F-3).
public final class SessionStore {

    public static let defaultRoot: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("STLTHRecorder/Sessions", isDirectory: true)
    }()

    public let root: URL
    private let fileManager: FileManager

    public init(root: URL = SessionStore.defaultRoot, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    // MARK: - Lifecycle

    /// Create the session directory and write `meta.json` with `status = recording`.
    ///
    /// Consent is captured *before* any audio is written — the point of the flow is
    /// that the confirmation and its timestamp are on record (F-4).
    public func begin(consentAt: Date) throws -> SessionHandle {
        let id = UUID()
        let dir = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let meta = SessionMeta(
            sessionId: id,
            startedAt: Date(),
            durationMs: 0,
            status: .recording,
            consent: .init(confirmed: true, at: consentAt),
            tracks: [.mic, .system],
            // Recorded up front, not only on completion. A session that a crash
            // leaves as "interrupted" is exactly the one where knowing which devices
            // were in use matters — and until now that was the one case where the
            // field stayed empty.
            devices: .init(input: DeviceMonitor.currentInputName,
                           output: DeviceMonitor.currentOutputName),
            deviceChanges: [],
            appVersion: Self.appVersion,
            osVersion: Self.osVersion
        )
        try meta.write(to: dir.appendingPathComponent("meta.json"))

        return SessionHandle(id: id, dir: dir)
    }

    /// Finalise a session: duration, devices and `status = completed`.
    public func complete(_ handle: SessionHandle, result: RecordingResult) throws {
        try update(handle) { meta in
            meta.status = .completed
            meta.durationMs = result.durationMs
            meta.devices = .init(input: result.inputDeviceName, output: result.outputDeviceName)
            meta.tracks = [.mic, .system]
            meta.captureMode = result.captureMode
            meta.deviceChanges = result.deviceChanges
        }
    }

    /// Mark a session as interrupted — used when the engine fails to start or dies
    /// mid-recording, so a half-written session is never left claiming "recording".
    public func interrupt(_ handle: SessionHandle) throws {
        try update(handle) { meta in
            meta.status = .interrupted
            if meta.durationMs == 0 {
                meta.durationMs = Self.durationMs(ofAudioIn: handle.dir)
            }
        }
    }

    /// Append a device change that happened mid-recording (spec §4).
    public func appendDeviceChange(_ handle: SessionHandle,
                                   at date: Date,
                                   input: String?,
                                   output: String?) throws {
        try update(handle) { meta in
            meta.deviceChanges.append(.init(at: date, input: input, output: output))
        }
    }

    public func delete(id: UUID) throws {
        let dir = root.appendingPathComponent(id.uuidString, isDirectory: true)
        guard fileManager.fileExists(atPath: dir.path) else { return }
        try fileManager.removeItem(at: dir)
    }

    // MARK: - Reading

    /// All sessions, newest first. Unreadable directories are skipped rather than
    /// failing the whole listing — one broken session must not hide the others.
    public func list() -> [SessionMeta] {
        guard let entries = try? fileManager.contentsOfDirectory(at: root,
                                                                 includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .compactMap { try? SessionMeta.load(from: $0.appendingPathComponent("meta.json")) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Recover sessions left in `recording` state by a crash or a kill.
    ///
    /// Audio was streamed to disk, so the files are intact — the real duration is
    /// simply how much audio actually landed there (spec §4).
    /// - Returns: directories that were actually repaired, so the caller can rebuild
    ///   whatever is derived from them — the mixdown in particular. Returning them
    ///   keeps that decision outside the core, which has no business reading settings.
    @discardableResult
    public func recoverInterrupted() -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(at: root,
                                                                 includingPropertiesForKeys: nil) else {
            return []
        }
        var recovered: [URL] = []

        for dir in entries {
            let metaURL = dir.appendingPathComponent("meta.json")
            guard var meta = try? SessionMeta.load(from: metaURL),
                  meta.status == .recording || meta.status == .interrupted else {
                continue
            }

            // Patch the CAF headers first: a killed writer never wrote the real data
            // chunk size, which makes the file unreadable outside Apple's frameworks.
            // Idempotent, so already-interrupted sessions are healed too.
            var repaired = false
            for name in ["mic.caf", "system.caf"] {
                repaired = CAFRepair.repairIfNeeded(at: dir.appendingPathComponent(name)) || repaired
            }

            guard meta.status == .recording || repaired else { continue }
            meta.status = .interrupted
            meta.durationMs = Self.durationMs(ofAudioIn: dir)
            try? meta.write(to: metaURL)
            recovered.append(dir)
        }
        return recovered
    }

    /// Record that a listening mixdown now exists beside the tracks.
    ///
    /// Written after the fact rather than at `complete()`: mixing happens in the
    /// background and must never hold up the end of a recording.
    public func noteMix(at sessionDir: URL, fileName: String) {
        let metaURL = sessionDir.appendingPathComponent("meta.json")
        guard var meta = try? SessionMeta.load(from: metaURL) else { return }
        meta.mixFile = fileName
        try? meta.write(to: metaURL)
    }

    /// Whether the source tracks may be deleted after a transcription run.
    ///
    /// A pure function, because this is the one decision in the product that destroys
    /// the user's data, and it has to be tested rather than guessed at along the way.
    ///
    /// The second condition is not a formality. A transcript with no lines means either
    /// recognition failed or nobody spoke — and deleting the audio at that moment is
    /// the worst possible outcome: the recording is gone, and what remains is a file
    /// that says «мовлення не розпізнано».
    public static func mayRemoveAudio(enabled: Bool, hadSpeech: Bool) -> Bool {
        enabled && hadSpeech
    }

    /// Delete the source tracks, keeping everything derived: the mixdown, the
    /// transcript and `meta.json`.
    ///
    /// Best effort, like `noteMix`: a track that cannot be removed simply stays for the
    /// next attempt, and the fact of removal is recorded only when something was
    /// actually freed — an empty directory is not "audio was deleted".
    /// - Returns: bytes freed.
    @discardableResult
    public func removeAudio(at sessionDir: URL) -> Int64 {
        var freed: Int64 = 0
        for name in ["mic.caf", "system.caf"] {
            let url = sessionDir.appendingPathComponent(name)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? Int64,
                  (try? fileManager.removeItem(at: url)) != nil else { continue }
            freed += size
        }
        if freed > 0 {
            let metaURL = sessionDir.appendingPathComponent("meta.json")
            if var meta = try? SessionMeta.load(from: metaURL) {
                meta.audioRemovedAt = Date()
                try? meta.write(to: metaURL)
            }
        }
        return freed
    }

    /// Duration of a session directory, taken from the *shorter* of the two tracks —
    /// the point past which we no longer have both channels.
    private static func durationMs(ofAudioIn dir: URL) -> Int {
        let durations = ["mic.caf", "system.caf"].compactMap { name -> Double? in
            let url = dir.appendingPathComponent(name)
            guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else {
                return nil
            }
            return Double(file.length) / file.fileFormat.sampleRate
        }
        guard let shortest = durations.min() else { return 0 }
        return Int((shortest * 1000).rounded())
    }

    // MARK: - Helpers

    private func update(_ handle: SessionHandle, _ mutate: (inout SessionMeta) -> Void) throws {
        let metaURL = handle.dir.appendingPathComponent("meta.json")
        var meta = try SessionMeta.load(from: metaURL)
        mutate(&meta)
        try meta.write(to: metaURL)
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
