import Foundation

/// One entry point for both ways a transcription can start — automatically after a
/// recording, or by hand from the session menu.
///
/// The Windows build calls this `RunAsync`, and the reason is the same: if the two
/// paths diverged, the same enabled option — deleting the audio, above all — would
/// behave differently depending on how the person started recognition, and there
/// would be nothing to explain that with.
public enum TranscriptionPipeline {

    public typealias Transcribe = (URL) throws -> Transcriber.TranscriptResult

    /// Transcribe the session and, if allowed, drop the source tracks.
    ///
    /// - Parameter deleteAudio: asked *after* the transcript is on disk. Whisper runs
    ///   for minutes, and a setting the user flips meanwhile should count.
    /// - Parameter transcribe: the real thing by default; tests hand in a stub so the
    ///   ordering can be checked without a model.
    /// - Returns: the transcription result; a failed removal never changes it.
    @discardableResult
    public static func run(sessionDir: URL,
                           store: SessionStore,
                           deleteAudio: () -> Bool,
                           transcribe: Transcribe = { try Transcriber.transcribe(sessionDir: $0) }
    ) throws -> Transcriber.TranscriptResult {
        let result = try transcribe(sessionDir)
        // Deletion last, and only on the tested condition: the transcript is already
        // written, so nothing that goes wrong here can take it away.
        if SessionStore.mayRemoveAudio(enabled: deleteAudio(), hadSpeech: result.hadSpeech) {
            store.removeAudio(at: sessionDir)
        }
        return result
    }
}
