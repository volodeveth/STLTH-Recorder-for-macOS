import AppKit
import Foundation
import RecorderCore
import SwiftUI

/// Transcribes sessions in the background, one at a time.
///
/// Lives in the app layer for the same reason `MixdownService` does: whether to
/// transcribe at all, and whether to delete the audio afterwards, are settings, and
/// the core has no business reading `@AppStorage`.
///
/// A failed transcription never makes a session look unsuccessful: the audio is still
/// there and the transcript can always be made again from the menu. The automatic
/// path logs and moves on; only a run the user started by hand gets an alert.
@MainActor
final class TranscriptionService: ObservableObject {

    /// Sessions queued or running, so the menu can say so.
    @Published private(set) var inProgress: Set<UUID> = []

    @AppStorage("autoTranscribe") var isEnabled = true
    @AppStorage("deleteAudioAfterTranscription") var deletesAudio = false

    private let store: SessionStore
    private let queue = SerialTaskQueue()

    init(store: SessionStore) {
        self.store = store
    }

    func isTranscribing(_ meta: SessionMeta) -> Bool {
        inProgress.contains(meta.sessionId)
    }

    func hasTranscript(_ meta: SessionMeta) -> Bool {
        FileManager.default.fileExists(atPath: transcriptURL(for: meta).path)
    }

    /// Whether either source track is still on disk. Once both are gone there is
    /// nothing to transcribe or to mix, and the menu must not promise otherwise.
    func hasAudio(_ meta: SessionMeta) -> Bool {
        let dir = directory(for: meta)
        return ["mic.caf", "system.caf"].contains {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    func transcriptURL(for meta: SessionMeta) -> URL {
        directory(for: meta).appendingPathComponent("transcript.md")
    }

    /// Transcribe automatically after a session is finished.
    ///
    /// Quiet when the models are absent: the offer to install them lives in the session
    /// menu, and must not pop up after every recording. Quiet, too, when a transcript
    /// already exists — a recovered session may have been transcribed before the crash.
    func transcribeAfterRecording(_ meta: SessionMeta?) {
        guard isEnabled, let meta, Transcriber.isAvailable, !hasTranscript(meta) else { return }
        transcribe(meta, announce: false)
    }

    /// Transcribe on demand, from the menu — or automatically, with `announce: false`.
    func transcribe(_ meta: SessionMeta, announce: Bool = true) {
        guard !inProgress.contains(meta.sessionId) else { return }
        inProgress.insert(meta.sessionId)

        let dir = directory(for: meta)
        Task { [store, queue] in
            let job = await queue.enqueue {
                try TranscriptionPipeline.run(sessionDir: dir, store: store,
                                              deleteAudio: { Self.mayDeleteAudio(in: dir) })
            }
            do {
                let result = try await job.value
                inProgress.remove(meta.sessionId)
                if announce { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
            } catch {
                inProgress.remove(meta.sessionId)
                NSLog("Транскрипт не створено: %@", error.localizedDescription)
                if announce {
                    let alert = NSAlert()
                    alert.messageText = "Не вдалося транскрибувати"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    /// The deletion decision, read when whisper has finished rather than when the job
    /// was queued, and read straight from defaults because it runs off the main actor.
    ///
    /// The mixdown is a second guard. It is built concurrently with transcription, and
    /// on a very short recording could still be encoding when the transcript lands —
    /// deleting the tracks under it would leave the session with no listening copy at
    /// all. So while mixdowns are on, the audio goes only once `session.m4a` exists.
    nonisolated private static func mayDeleteAudio(in dir: URL) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "deleteAudioAfterTranscription") else { return false }
        let mixdownEnabled = defaults.object(forKey: "createMixdown") as? Bool ?? true
        return !mixdownEnabled || SessionMixer.mixExists(in: dir)
    }

    private func directory(for meta: SessionMeta) -> URL {
        store.root.appendingPathComponent(meta.sessionId.uuidString, isDirectory: true)
    }
}
