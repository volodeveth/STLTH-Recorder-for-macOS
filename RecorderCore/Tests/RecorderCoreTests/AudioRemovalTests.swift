import Foundation
import Testing
@testable import RecorderCore

/// The only place in the product that deletes the user's recordings. So the rule is
/// checked from both sides: that it fires, and — above all — when it must not.
@Suite("Audio removal")
struct AudioRemovalTests {

    private func makeStore() throws -> SessionStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stlth-audio-removal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return SessionStore(root: root)
    }

    /// A session with two tracks. Their contents do not matter here — removal never
    /// opens them — so a few kilobytes stand in for an hour of audio.
    private func sessionWithAudio(in store: SessionStore) throws -> SessionHandle {
        let handle = try store.begin(consentAt: Date())
        try Data(repeating: 0x11, count: 4096).write(to: handle.dir.appendingPathComponent("mic.caf"))
        try Data(repeating: 0x22, count: 8192).write(to: handle.dir.appendingPathComponent("system.caf"))
        return handle
    }

    private func meta(of handle: SessionHandle) throws -> SessionMeta {
        try SessionMeta.load(from: handle.dir.appendingPathComponent("meta.json"))
    }

    private func exists(_ name: String, in handle: SessionHandle) -> Bool {
        FileManager.default.fileExists(atPath: handle.dir.appendingPathComponent(name).path)
    }

    // MARK: - The decision

    @Test("Nothing is deleted while the option is off")
    func offMeansNever() {
        #expect(!SessionStore.mayRemoveAudio(enabled: false, hadSpeech: true))
        #expect(!SessionStore.mayRemoveAudio(enabled: false, hadSpeech: false))
    }

    @Test("Nothing is deleted when the transcript found no speech")
    func silenceKeepsAudio() {
        // The worst possible outcome: the recording is gone and what remains is a file
        // saying «мовлення не розпізнано». An empty transcript is a reason to keep the
        // audio, not to get rid of it.
        #expect(!SessionStore.mayRemoveAudio(enabled: true, hadSpeech: false))
    }

    @Test("Deletion needs both the option and actual speech")
    func bothConditions() {
        #expect(SessionStore.mayRemoveAudio(enabled: true, hadSpeech: true))
    }

    // MARK: - The removal

    @Test("Removing audio frees the tracks and keeps everything derived")
    func keepsDerivedFiles() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let handle = try sessionWithAudio(in: store)
        try Data("# текст".utf8).write(to: handle.dir.appendingPathComponent("transcript.md"))
        try Data("звук".utf8).write(to: handle.dir.appendingPathComponent("session.m4a"))

        let freed = store.removeAudio(at: handle.dir)

        #expect(freed == 4096 + 8192)
        #expect(!exists("mic.caf", in: handle))
        #expect(!exists("system.caf", in: handle))
        #expect(exists("transcript.md", in: handle))
        #expect(exists("session.m4a", in: handle))
        #expect(exists("meta.json", in: handle))
    }

    @Test("The removal is written into meta.json")
    func removalIsRecorded() throws {
        // The difference between "the files were removed on purpose" and "the files
        // vanished" has to be on record, not reconstructed by guesswork in six months.
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let handle = try sessionWithAudio(in: store)

        let before = Date()
        store.removeAudio(at: handle.dir)

        let removedAt = try #require(try meta(of: handle).audioRemovedAt)
        #expect(abs(removedAt.timeIntervalSince(before)) < 5)
    }

    @Test("A session without audio still lists")
    func stillLists() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let handle = try sessionWithAudio(in: store)
        store.removeAudio(at: handle.dir)

        let listed = store.list()

        #expect(listed.count == 1)
        #expect(listed.first?.sessionId == handle.id)
        #expect(listed.first?.audioRemovedAt != nil)
    }

    @Test("Removing twice frees nothing the second time")
    func idempotent() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let handle = try sessionWithAudio(in: store)

        #expect(store.removeAudio(at: handle.dir) > 0)
        let firstStamp = try meta(of: handle).audioRemovedAt
        #expect(store.removeAudio(at: handle.dir) == 0)
        // The second, empty pass must not rewrite the timestamp either.
        #expect(try meta(of: handle).audioRemovedAt == firstStamp)
    }

    @Test("A session that never had audio is not marked as stripped")
    func emptyDirectoryIsNotStripped() throws {
        // An empty directory is not "the audio was deleted", and saying so would be a lie.
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let handle = try store.begin(consentAt: Date())

        #expect(store.removeAudio(at: handle.dir) == 0)
        #expect(try meta(of: handle).audioRemovedAt == nil)
    }

    @Test("A missing session directory frees nothing and does not throw")
    func missingDirectory() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        #expect(store.removeAudio(at: store.root.appendingPathComponent("nope")) == 0)
    }

    // MARK: - meta.json compatibility

    @Test("audioRemovedAt survives a write/load round trip")
    func roundTrip() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let handle = try store.begin(consentAt: Date())
        let url = handle.dir.appendingPathComponent("meta.json")

        var meta = try SessionMeta.load(from: url)
        let stamp = Date(timeIntervalSince1970: 1_800_000_000.5)
        meta.audioRemovedAt = stamp
        try meta.write(to: url)

        let reloaded = try SessionMeta.load(from: url)
        let restored = try #require(reloaded.audioRemovedAt)
        #expect(abs(restored.timeIntervalSince(stamp)) < 0.001)

        // The key is spelled the way the Windows build spells it, so one analytics
        // reader serves both platforms' meta.json.
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"audioRemovedAt\""))
    }

    @Test("A meta.json written before the field existed still decodes")
    func oldMetaDecodes() throws {
        // Recordings made before this option existed are read without any change.
        let json = """
        {
          "appVersion" : "1.2.0",
          "consent" : { "at" : "2026-08-12T14:00:03.412+03:00", "confirmed" : true },
          "deviceChanges" : [],
          "devices" : { "input" : "MacBook Pro Microphone", "output" : "MacBook Pro Speakers" },
          "durationMs" : 1500,
          "osVersion" : "15.0.0",
          "sessionId" : "B7F0E7A4-5F0B-4B2E-9F3B-7C1B2D3E4F50",
          "startedAt" : "2026-08-12T14:00:03.500+03:00",
          "status" : "completed",
          "tracks" : [
            { "channel" : "mic", "channels" : 1, "file" : "mic.caf", "format" : "caf/lpcm",
              "sampleRate" : 48000, "speaker" : "advisor" },
            { "channel" : "system", "channels" : 2, "file" : "system.caf", "format" : "caf/lpcm",
              "sampleRate" : 48000, "speaker" : "client" }
          ]
        }
        """
        let meta = try SessionMeta.decoder.decode(SessionMeta.self, from: Data(json.utf8))
        #expect(meta.audioRemovedAt == nil)
        #expect(meta.mixFile == nil)
        #expect(meta.captureMode == nil)
        #expect(meta.status == .completed)
        // 1.2.0 labelled the tracks advisor/client; 1.3.0 writes local/remote. The
        // field is a plain string, so old sessions keep their labels and still load.
        #expect(meta.tracks.map(\.speaker) == ["advisor", "client"])
        #expect(SessionMeta.Track.mic.speaker == "local")
        #expect(SessionMeta.Track.system.speaker == "remote")
    }

    @Test("A session written today omits the key rather than writing null")
    func absentFieldIsOmitted() throws {
        // `mixFile` and `captureMode` already behave this way; a `null` would make every
        // untouched session look like it had something to say about audio removal.
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let handle = try store.begin(consentAt: Date())

        let text = try String(contentsOf: handle.dir.appendingPathComponent("meta.json"), encoding: .utf8)
        #expect(!text.contains("audioRemovedAt"))
    }
}
