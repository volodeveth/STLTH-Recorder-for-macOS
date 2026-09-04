import Foundation
import Testing
@testable import RecorderCore

/// The pipeline is the single place where "transcribe" and "maybe delete the audio"
/// meet, so its ordering is checked here with whisper replaced by a stub that writes
/// a transcript and reports whether it "heard" anything.
@Suite("TranscriptionPipeline")
struct TranscriptionPipelineTests {

    private struct Broken: Error {}

    private func makeSession() throws -> (SessionStore, SessionHandle) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stlth-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SessionStore(root: root)
        let handle = try store.begin(consentAt: Date())
        try Data(repeating: 1, count: 1024).write(to: handle.dir.appendingPathComponent("mic.caf"))
        try Data(repeating: 2, count: 1024).write(to: handle.dir.appendingPathComponent("system.caf"))
        return (store, handle)
    }

    private func stub(hadSpeech: Bool) -> TranscriptionPipeline.Transcribe {
        { dir in
            let url = dir.appendingPathComponent("transcript.md")
            try Data("# Транскрипт".utf8).write(to: url)
            return Transcriber.TranscriptResult(url: url, hadSpeech: hadSpeech)
        }
    }

    private func hasAudio(_ handle: SessionHandle) -> Bool {
        FileManager.default.fileExists(atPath: handle.dir.appendingPathComponent("mic.caf").path)
            && FileManager.default.fileExists(atPath: handle.dir.appendingPathComponent("system.caf").path)
    }

    private func audioRemovedAt(_ handle: SessionHandle) throws -> Date? {
        try SessionMeta.load(from: handle.dir.appendingPathComponent("meta.json")).audioRemovedAt
    }

    @Test("With the option on and speech found, the tracks go and the transcript stays")
    func removesWhenAllowed() throws {
        let (store, handle) = try makeSession()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let result = try TranscriptionPipeline.run(sessionDir: handle.dir, store: store,
                                                   deleteAudio: { true },
                                                   transcribe: stub(hadSpeech: true))

        #expect(result.hadSpeech)
        #expect(!hasAudio(handle))
        #expect(FileManager.default.fileExists(atPath: result.url.path))
        #expect(try audioRemovedAt(handle) != nil)
    }

    @Test("A transcript with no speech keeps the audio even with the option on")
    func keepsAudioOnSilence() throws {
        let (store, handle) = try makeSession()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let result = try TranscriptionPipeline.run(sessionDir: handle.dir, store: store,
                                                   deleteAudio: { true },
                                                   transcribe: stub(hadSpeech: false))

        #expect(!result.hadSpeech)
        #expect(hasAudio(handle))
        #expect(try audioRemovedAt(handle) == nil)
    }

    @Test("With the option off nothing is deleted")
    func keepsAudioWhenOff() throws {
        let (store, handle) = try makeSession()
        defer { try? FileManager.default.removeItem(at: store.root) }

        try TranscriptionPipeline.run(sessionDir: handle.dir, store: store,
                                      deleteAudio: { false },
                                      transcribe: stub(hadSpeech: true))

        #expect(hasAudio(handle))
        #expect(try audioRemovedAt(handle) == nil)
    }

    @Test("A failed transcription propagates and touches no audio")
    func failureKeepsAudio() throws {
        let (store, handle) = try makeSession()
        defer { try? FileManager.default.removeItem(at: store.root) }

        #expect(throws: Broken.self) {
            try TranscriptionPipeline.run(sessionDir: handle.dir, store: store,
                                          deleteAudio: { true },
                                          transcribe: { _ in throw Broken() })
        }
        #expect(hasAudio(handle))
        #expect(!FileManager.default.fileExists(atPath: handle.dir.appendingPathComponent("transcript.md").path))
    }

    @Test("The deletion decision is read after transcription, not before")
    func decisionIsReadLate() throws {
        // The setting can change while a long job is running; the value that counts is
        // the one at the moment of deletion, which is what the Windows build does too.
        let (store, handle) = try makeSession()
        defer { try? FileManager.default.removeItem(at: store.root) }
        var transcribed = false

        try TranscriptionPipeline.run(sessionDir: handle.dir, store: store,
                                      deleteAudio: { transcribed },
                                      transcribe: { dir in
                                          transcribed = true
                                          return try self.stub(hadSpeech: true)(dir)
                                      })

        #expect(!hasAudio(handle))
    }

    @Test("The default transcriber is the real one, which refuses a session with no tracks")
    func defaultTranscriberIsWired() throws {
        // Without whisper on the bench the real path fails early — either because the
        // tool or model is missing, or because there is nothing to transcribe. Any of
        // those proves the default closure reaches `Transcriber`; none of them may
        // delete anything.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stlth-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root)
        let handle = try store.begin(consentAt: Date())

        #expect(throws: Transcriber.TranscriberError.self) {
            try TranscriptionPipeline.run(sessionDir: handle.dir, store: store, deleteAudio: { true })
        }
        #expect(try audioRemovedAt(handle) == nil)
    }
}
