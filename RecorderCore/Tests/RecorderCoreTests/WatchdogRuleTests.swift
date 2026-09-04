import Testing
@testable import RecorderCore

/// The rule that decides whether a silent capture is broken or merely quiet.
///
/// Measured on hardware (`Tools/running-probe`): a process tap delivers nothing at
/// all until some process starts playing, and once it starts it keeps delivering
/// through silence at full rate — 94 callbacks/s through 40 s of quiet, with
/// `kAudioDevicePropertyDeviceIsRunning` reporting true the whole time.
///
/// Those two facts are what make the plan's original "no callbacks for 3 s → rebuild"
/// safe *only* with preconditions. Without them it fires on every meeting that opens
/// in silence.
@Suite("Watchdog rule")
struct WatchdogRuleTests {

    @Test("A meeting that opens in silence is not a stall")
    func silenceBeforeTheFirstCallbackIsNotAStall() {
        // Nobody has spoken yet: the tap has never run, so no callbacks is expected.
        #expect(AudioEngine.shouldRebuild(hasEverReceivedCallback: false,
                                          secondsSinceLastCallback: 30,
                                          deviceReportsRunning: false) == false)
    }

    @Test("Not even a long opening silence with the device already running")
    func silenceBeforeFirstCallbackNeverRebuilds() {
        #expect(AudioEngine.shouldRebuild(hasEverReceivedCallback: false,
                                          secondsSinceLastCallback: 600,
                                          deviceReportsRunning: true) == false)
    }

    @Test("Callbacks stopping while the device claims to run is a stall")
    func stalledStreamIsDetected() {
        #expect(AudioEngine.shouldRebuild(hasEverReceivedCallback: true,
                                          secondsSinceLastCallback: 3.5,
                                          deviceReportsRunning: true) == true)
    }

    @Test("A pause shorter than the threshold is left alone")
    func briefGapIsTolerated() {
        #expect(AudioEngine.shouldRebuild(hasEverReceivedCallback: true,
                                          secondsSinceLastCallback: 2.9,
                                          deviceReportsRunning: true) == false)
    }

    @Test("A device that stopped is not rebuilt — a new graph would idle too")
    func stoppedDeviceIsNotRebuilt() {
        // If the device itself reports not running, rebuilding produces another idle
        // graph. That is a different failure and needs a different answer.
        #expect(AudioEngine.shouldRebuild(hasEverReceivedCallback: true,
                                          secondsSinceLastCallback: 30,
                                          deviceReportsRunning: false) == false)
    }

    @Test("Ten minutes of remote silence do not trigger a rebuild (ТЗ критерій №4)")
    func tenMinutesOfSilenceDoNotRebuild() {
        // The stream is running and delivering zero-filled buffers, so the time since
        // the last callback stays near zero no matter how long the room is quiet.
        #expect(AudioEngine.shouldRebuild(hasEverReceivedCallback: true,
                                          secondsSinceLastCallback: 0.01,
                                          deviceReportsRunning: true) == false)
    }
}
