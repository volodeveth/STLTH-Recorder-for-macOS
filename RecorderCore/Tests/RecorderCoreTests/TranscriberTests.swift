import Foundation
import Testing
@testable import RecorderCore

/// The transcript's "did anyone speak" bit feeds the one decision in the product that
/// destroys data — deleting the source tracks — so it is checked on its own, without
/// whisper in the loop.
@Suite("Transcriber")
struct TranscriberTests {

    @Test("No lines on any track counts as silence")
    func emptySectionsAreSilence() {
        #expect(!Transcriber.hasSpeech([(title: "Радник", lines: []), (title: "Клієнт", lines: [])]))
        #expect(!Transcriber.hasSpeech([]))
    }

    @Test("One line on one track is enough to count as speech")
    func anyLineIsSpeech() {
        #expect(Transcriber.hasSpeech([
            (title: "Радник", lines: []),
            (title: "Клієнт", lines: [(1200, "Добрий день")]),
        ]))
    }

    @Test("The result carries the transcript's location and the speech flag together")
    func resultIsPlainData() {
        let url = URL(fileURLWithPath: "/tmp/transcript.md")
        let result = Transcriber.TranscriptResult(url: url, hadSpeech: true)
        #expect(result.url == url)
        #expect(result.hadSpeech)
        #expect(result == Transcriber.TranscriptResult(url: url, hadSpeech: true))
    }
}
