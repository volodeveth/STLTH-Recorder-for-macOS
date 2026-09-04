import Testing
@testable import RecorderCore

/// The timeline invariant (spec §3): every track holds exactly `duration × 48000`
/// samples. Silence is written, never cut out — so a gap in the audio stream
/// (device change, CoreAudio hiccup, sleep) must be padded, not skipped.
@Suite("TimelineAccountant")
struct TimelineAccountantTests {

    @Test("Contiguous buffers need no padding")
    func contiguousBuffersNeedNoPadding() {
        var acc = TimelineAccountant(sampleRate: 48000)
        #expect(acc.frames(toInsertBefore: 0.0, frameCount: 480) == 0)
        #expect(acc.frames(toInsertBefore: 0.01, frameCount: 480) == 0) // exactly the next buffer
        #expect(acc.totalFrames == 960)
    }

    @Test("A gap is padded with silence")
    func gapIsPaddedWithSilence() {
        var acc = TimelineAccountant(sampleRate: 48000)
        _ = acc.frames(toInsertBefore: 0.0, frameCount: 480)
        // Previous buffer ended at 0.01 s; this one starts at 2.01 s
        // => 2.0 s of silence = 96000 frames.
        #expect(acc.frames(toInsertBefore: 2.01, frameCount: 480) == 96000)
        #expect(acc.totalFrames == 480 + 96000 + 480)
    }

    @Test("Jitter below the tolerance is not a gap")
    func jitterBelowThresholdIgnored() {
        var acc = TimelineAccountant(sampleRate: 48000)
        _ = acc.frames(toInsertBefore: 0.0, frameCount: 480)
        #expect(acc.frames(toInsertBefore: 0.0105, frameCount: 480) == 0) // 0.5 ms jitter
    }

    @Test("A buffer arriving early never rewinds the timeline")
    func earlyBufferNeverProducesNegativePadding() {
        var acc = TimelineAccountant(sampleRate: 48000)
        _ = acc.frames(toInsertBefore: 0.0, frameCount: 480)
        #expect(acc.frames(toInsertBefore: 0.005, frameCount: 480) == 0)
        #expect(acc.totalFrames == 960)
    }

    @Test("Total frames still match wall clock across a 10-minute gap")
    func totalFramesMatchWallClockOverALongGap() {
        var acc = TimelineAccountant(sampleRate: 48000)
        _ = acc.frames(toInsertBefore: 0.0, frameCount: 480)
        let resumeAt = 0.01 + 600.0
        let pad = acc.frames(toInsertBefore: resumeAt, frameCount: 480)

        #expect(pad == 600 * 48000)
        // duration × 48000 invariant: the last buffer ends at resumeAt + 0.01 s
        let expected = (resumeAt + 0.01) * 48000
        #expect(abs(Double(acc.totalFrames) - expected) <= 1.0)
    }

    @Test("Works at other sample rates")
    func worksAtOtherSampleRates() {
        var acc = TimelineAccountant(sampleRate: 44100)
        _ = acc.frames(toInsertBefore: 0.0, frameCount: 441)
        #expect(acc.frames(toInsertBefore: 1.01, frameCount: 441) == 44100)
    }

    // MARK: - Silence at the edges of the session
    //
    // A process tap only runs while something is actually playing. A meeting that
    // starts before anyone speaks, or ends in silence, therefore delivers no buffers
    // at all for those stretches — and on the bench an 8-second recording in silence
    // produced a 0-sample file. Wall-clock length has to be enforced by the session's
    // own start and stop times, not only by the gaps between buffers.

    @Test("Silence before the first buffer is padded, not swallowed")
    func leadingSilenceIsPadded() {
        var acc = TimelineAccountant(sampleRate: 48000)
        acc.start(at: 100.0)
        // Nothing played for the first 3 seconds of the session.
        #expect(acc.frames(toInsertBefore: 103.0, frameCount: 480) == 3 * 48000)
        #expect(acc.totalFrames == 3 * 48000 + 480)
    }

    @Test("Silence after the last buffer is padded up to the stop time")
    func trailingSilenceIsPadded() {
        var acc = TimelineAccountant(sampleRate: 48000)
        acc.start(at: 100.0)
        _ = acc.frames(toInsertBefore: 100.0, frameCount: 480) // one buffer, then quiet
        #expect(acc.frames(toReach: 105.0) == 5 * 48000 - 480)
        #expect(acc.totalFrames == 5 * 48000)
    }

    @Test("A session with no audio at all is still full length")
    func sessionWithNoBuffersIsStillFullLength() {
        var acc = TimelineAccountant(sampleRate: 48000)
        acc.start(at: 100.0)
        #expect(acc.frames(toReach: 108.0) == 8 * 48000)
        #expect(acc.totalFrames == 8 * 48000)
    }

    @Test("Reaching a time already covered adds nothing")
    func reachingAnAlreadyCoveredTimeAddsNothing() {
        var acc = TimelineAccountant(sampleRate: 48000)
        acc.start(at: 100.0)
        _ = acc.frames(toInsertBefore: 100.0, frameCount: 48000) // one second of audio
        #expect(acc.frames(toReach: 100.5) == 0)
        #expect(acc.totalFrames == 48000)
    }

    @Test("Ten minutes of mute keep both tracks the same length (ТЗ критерій №4)")
    func tenMinutesOfMuteKeepTracksAligned() {
        // The client's channel goes quiet for ten minutes while the advisor keeps
        // talking. The tap stops delivering; the microphone does not.
        var system = TimelineAccountant(sampleRate: 48000)
        var mic = TimelineAccountant(sampleRate: 48000)
        system.start(at: 0)
        mic.start(at: 0)

        _ = system.frames(toInsertBefore: 0.0, frameCount: 480)
        var micTime = 0.0
        while micTime < 600.01 {
            _ = mic.frames(toInsertBefore: micTime, frameCount: 480)
            micTime += 0.01
        }

        _ = system.frames(toReach: micTime)
        _ = mic.frames(toReach: micTime)
        #expect(system.totalFrames == mic.totalFrames)
    }
}
