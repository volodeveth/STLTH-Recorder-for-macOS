import AVFoundation
import Foundation
import Testing
@testable import RecorderCore

@Suite("SessionStore")
struct SessionStoreTests {

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stlth-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeResult(in directory: URL, durationMs: Int = 1500) throws -> RecordingResult {
        RecordingResult(
            micURL: directory.appendingPathComponent("mic.caf"),
            systemURL: directory.appendingPathComponent("system.caf"),
            durationMs: durationMs,
            inputDeviceName: "MacBook Pro Microphone",
            outputDeviceName: "AirPods Pro"
        )
    }

    @Test("Devices switched mid-session are recorded in meta.json")
    func deviceChangesReachMeta() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(root: root)
        let handle = try store.begin(consentAt: Date())

        // The advisor plugs in AirPods ten minutes into the meeting: the engine
        // rebuilds its aggregate, and the session has to say so — otherwise a gap in
        // the audio later looks like a bug instead of a documented device switch.
        let switchedAt = Date()
        let result = RecordingResult(
            micURL: handle.dir.appendingPathComponent("mic.caf"),
            systemURL: handle.dir.appendingPathComponent("system.caf"),
            durationMs: 1500,
            inputDeviceName: "AirPods Pro",
            outputDeviceName: "AirPods Pro",
            deviceChanges: [
                SessionMeta.DeviceChange(at: switchedAt, output: "AirPods Pro"),
                SessionMeta.DeviceChange(at: switchedAt, input: "AirPods Pro"),
            ]
        )
        try store.complete(handle, result: result)

        let meta = try SessionMeta.load(from: handle.dir.appendingPathComponent("meta.json"))
        #expect(meta.deviceChanges.count == 2)
        #expect(meta.deviceChanges[0].output == "AirPods Pro")
        #expect(meta.deviceChanges[0].input == nil)
        #expect(meta.deviceChanges[1].input == "AirPods Pro")
        #expect(abs(meta.deviceChanges[0].at.timeIntervalSince(switchedAt)) < 1.0)
    }

    // MARK: - begin

    @Test("begin creates the session directory and a recording meta.json")
    func beginCreatesSession() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(root: root)
        let consentAt = Date()
        let handle = try store.begin(consentAt: consentAt)

        #expect(FileManager.default.fileExists(atPath: handle.dir.path))
        let metaURL = handle.dir.appendingPathComponent("meta.json")
        #expect(FileManager.default.fileExists(atPath: metaURL.path))

        let meta = try SessionMeta.load(from: metaURL)
        #expect(meta.sessionId == handle.id)
        #expect(meta.status == .recording)
        #expect(meta.consent.confirmed == true)
        #expect(abs(meta.consent.at.timeIntervalSince(consentAt)) < 1.0)
        #expect(meta.durationMs == 0)
    }

    // MARK: - complete

    @Test("complete fills duration, tracks and devices and marks the session completed")
    func completeFinalisesSession() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(root: root)
        let handle = try store.begin(consentAt: Date())
        try store.complete(handle, result: makeResult(in: handle.dir, durationMs: 3127000))

        let meta = try SessionMeta.load(from: handle.dir.appendingPathComponent("meta.json"))
        #expect(meta.status == .completed)
        #expect(meta.durationMs == 3127000)
        #expect(meta.devices.input == "MacBook Pro Microphone")
        #expect(meta.devices.output == "AirPods Pro")
        #expect(meta.tracks.count == 2)

        let mic = try #require(meta.tracks.first { $0.channel == "mic" })
        #expect(mic.speaker == "advisor")
        #expect(mic.file == "mic.caf")
        #expect(mic.channels == 1)
        #expect(mic.sampleRate == 48000)
        #expect(mic.format == "caf/lpcm")

        let system = try #require(meta.tracks.first { $0.channel == "system" })
        #expect(system.speaker == "client")
        #expect(system.file == "system.caf")
        #expect(system.channels == 2)
    }

    // MARK: - serialisation

    @Test("meta.json round-trips and keeps the local time zone offset")
    func metaRoundTrips() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(root: root)
        let handle = try store.begin(consentAt: Date())
        try store.complete(handle, result: makeResult(in: handle.dir))

        let metaURL = handle.dir.appendingPathComponent("meta.json")
        let meta = try SessionMeta.load(from: metaURL)
        let json = try String(contentsOf: metaURL, encoding: .utf8)

        // Spec §2 shows an offset-bearing timestamp such as 2026-08-12T14:00:03+03:00.
        // The offset may be +HH:MM, -HH:MM or Z — all three are valid ISO 8601.
        #expect(json.contains("\"startedAt\""))
        let startedAtLine = try #require(json.split(separator: "\n").first { $0.contains("startedAt") })
        let value = try #require(startedAtLine.split(separator: "\"").last { $0.contains("T") })
        let hasOffset = value.hasSuffix("Z")
            || value.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) != nil
        #expect(hasOffset, "startedAt має нести зсув часового поясу, отримано: \(value)")

        // And the whole document survives a decode/encode cycle unchanged.
        let reencoded = try SessionMeta.encoder.encode(meta)
        let decoded = try SessionMeta.decoder.decode(SessionMeta.self, from: reencoded)
        #expect(decoded.sessionId == meta.sessionId)
        #expect(decoded.status == meta.status)
        #expect(decoded.tracks.count == meta.tracks.count)
        #expect(abs(decoded.startedAt.timeIntervalSince(meta.startedAt)) < 1.0)
    }

    @Test("meta.json is valid JSON with all fields required by the spec")
    func metaMatchesSpec() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(root: root)
        let handle = try store.begin(consentAt: Date())
        try store.complete(handle, result: makeResult(in: handle.dir))

        let data = try Data(contentsOf: handle.dir.appendingPathComponent("meta.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        for key in ["sessionId", "startedAt", "durationMs", "status", "consent",
                    "tracks", "devices", "deviceChanges", "appVersion", "osVersion"] {
            #expect(object[key] != nil, "meta.json має містити поле \(key)")
        }
    }

    // MARK: - recovery

    @Test("an interrupted session is recovered with a duration taken from the audio files")
    func recoversInterruptedSession() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(root: root)
        let handle = try store.begin(consentAt: Date())

        // Simulate a crash: audio was streamed to disk, meta.json still says "recording".
        var mic: CAFWriter? = try CAFWriter(url: handle.dir.appendingPathComponent("mic.caf"), channels: 1)
        try mic?.writeSilence(frames: 2 * 48000) // 2 seconds
        mic = nil
        var system: CAFWriter? = try CAFWriter(url: handle.dir.appendingPathComponent("system.caf"), channels: 2)
        try system?.writeSilence(frames: 2 * 48000)
        system = nil

        store.recoverInterrupted()

        let meta = try SessionMeta.load(from: handle.dir.appendingPathComponent("meta.json"))
        #expect(meta.status == .interrupted)
        #expect(meta.durationMs == 2000)
    }

    @Test("recovery leaves completed sessions untouched")
    func recoveryIgnoresCompletedSessions() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(root: root)
        let handle = try store.begin(consentAt: Date())
        try store.complete(handle, result: makeResult(in: handle.dir, durationMs: 4242))

        store.recoverInterrupted()

        let meta = try SessionMeta.load(from: handle.dir.appendingPathComponent("meta.json"))
        #expect(meta.status == .completed)
        #expect(meta.durationMs == 4242)
    }

    // MARK: - list & delete

    @Test("list returns sessions newest first")
    func listSortsNewestFirst() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(root: root)
        let older = try store.begin(consentAt: Date(timeIntervalSinceNow: -600))
        Thread.sleep(forTimeInterval: 0.01)
        let newer = try store.begin(consentAt: Date())

        let sessions = store.list()
        #expect(sessions.count == 2)
        #expect(sessions.first?.sessionId == newer.id)
        #expect(sessions.last?.sessionId == older.id)
    }

    @Test("delete removes the whole session directory")
    func deleteRemovesDirectory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(root: root)
        let handle = try store.begin(consentAt: Date())
        #expect(FileManager.default.fileExists(atPath: handle.dir.path))

        try store.delete(id: handle.id)
        #expect(!FileManager.default.fileExists(atPath: handle.dir.path))
        #expect(store.list().isEmpty)
    }

    @Test("a directory without meta.json is ignored instead of crashing the list")
    func listSkipsGarbage() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(root: root)
        _ = try store.begin(consentAt: Date())
        try FileManager.default.createDirectory(at: root.appendingPathComponent("not-a-session"),
                                                withIntermediateDirectories: true)

        #expect(store.list().count == 1)
    }

    @Test("a device change is appended to meta.json")
    func recordsDeviceChange() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(root: root)
        let handle = try store.begin(consentAt: Date())
        try store.appendDeviceChange(handle, at: Date(), input: "AirPods Pro", output: nil)

        let meta = try SessionMeta.load(from: handle.dir.appendingPathComponent("meta.json"))
        #expect(meta.deviceChanges.count == 1)
        #expect(meta.deviceChanges.first?.input == "AirPods Pro")
    }
}
