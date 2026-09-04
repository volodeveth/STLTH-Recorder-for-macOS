import AVFoundation
import CoreAudio
import Foundation
import OSLog

/// Captures a meeting into two synchronised tracks.
///
/// Architecture (spec §1): a **global process tap** (everything the system plays,
/// minus our own process) and the **default input device** are placed in a *single*
/// aggregate device. One device → one IO callback → one clock, so the two tracks
/// cannot drift apart: the <300 ms requirement is satisfied by construction rather
/// than by post-hoc correction.
///
/// Every CoreAudio call here is mirrored from `docs/notes/audiocap-findings.md`,
/// which was written from AudioCap's real source and verified against the SDK
/// headers and a hardware spike (`Tools/spike/main.swift`).
public final class AudioEngine: AudioEngineProtocol {

    private let logger = Logger(subsystem: "ua.stlth.STLTHRecorder", category: "AudioEngine")

    public let sessionDir: URL

    // CoreAudio objects, all torn down in `stop()`.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapUUID = UUID()

    // Writers and their timeline bookkeeping.
    private var micWriter: CAFWriter?
    private var systemWriter: CAFWriter?
    private var micTimeline = TimelineAccountant(sampleRate: 48000)
    private var systemTimeline = TimelineAccountant(sampleRate: 48000)

    /// Which callback buffer carries which source. Resolved at start from the
    /// device's actual stream configuration — never assumed.
    private var micBufferIndex: Int?
    private var systemBufferIndex: Int?
    private var micChannelCount: UInt32 = 0
    private var hasInputDevice = false
    /// True when the same physical device serves as both input and output, so it
    /// appears once in the aggregate and still delivers input channels.
    private var inputSharesOutputDevice = false
    private var layoutResolved = false
    /// Separate IO proc used when the aggregate refuses to run with the microphone.
    private var micDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var micProcID: AudioDeviceIOProcID?
    private var micFallbackSampleRate: Double = 48000
    private let micQueue = DispatchQueue(label: "ua.stlth.STLTHRecorder.mic", qos: .userInitiated)
    public private(set) var micCallbackCount = 0
    private var captureMode: CaptureMode = .singleAggregate
    /// Number of IO callbacks received — surfaced so the CLI bench can tell
    /// "no callbacks at all" apart from "callbacks full of silence".
    public private(set) var callbackCount = 0
    /// True once a system buffer carried anything but digital silence.
    ///
    /// This is the only honest signal that the system-audio permission was granted:
    /// when it is missing, CoreAudio still delivers callbacks at full rate, filled
    /// with zeroes. Counting callbacks cannot tell the two apart.
    public private(set) var systemAudioDetected = false

    private func noteSystemAudio(in buffer: AudioBuffer) {
        guard !systemAudioDetected, let data = buffer.mData else { return }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        let samples = data.bindMemory(to: Float.self, capacity: count)
        for index in 0..<count where abs(samples[index]) > 0.0001 {
            systemAudioDetected = true
            return
        }
    }

    /// How long CoreAudio setup may block before we stop waiting on it.
    private static let setupDeadline: TimeInterval = 4

    /// Rebuilds triggered by the user switching devices mid-meeting.
    private let deviceMonitor = DeviceMonitor()
    private var deviceChanges: [SessionMeta.DeviceChange] = []
    /// Serialises rebuilds so two device changes in a row cannot overlap.
    private let controlQueue = DispatchQueue(label: "ua.stlth.STLTHRecorder.control")

    /// Carries an error out of a closure that runs on another thread.
    private final class ErrorBox: @unchecked Sendable {
        var error: Error?
    }

    /// Silence this long with the device still claiming to run means a real stall.
    private static let stallThreshold: TimeInterval = 3

    private var watchdogTimer: DispatchSourceTimer?
    private var lastCallbackAt: Double = 0
    private var hasEverReceivedCallback = false

    /// Should the capture graph be rebuilt?
    ///
    /// The plan asked for "no IO callback for 3 s → rebuild". Measured on hardware
    /// (`Tools/running-probe`), that rule is wrong on its own: a process tap delivers
    /// nothing at all until some process starts playing, so a meeting that opens in
    /// silence would be "repaired" over and over. The same probe showed the flip side —
    /// once the stream starts it keeps running through silence at full rate, and
    /// `kAudioDevicePropertyDeviceIsRunning` tracks that exactly.
    ///
    /// So a genuine stall has a signature the quiet case cannot forge: the stream has
    /// run at least once, the device still reports itself running, and yet nothing is
    /// arriving.
    static func shouldRebuild(hasEverReceivedCallback: Bool,
                              secondsSinceLastCallback: Double,
                              deviceReportsRunning: Bool,
                              threshold: TimeInterval = AudioEngine.stallThreshold) -> Bool {
        guard hasEverReceivedCallback else { return false }
        guard deviceReportsRunning else { return false }
        return secondsSinceLastCallback > threshold
    }

    private var inputDeviceName = "Немає мікрофона"
    private var outputDeviceName = "Невідомий пристрій"
    private var tapFormat: AVAudioFormat?

    private let ioQueue = DispatchQueue(label: "ua.stlth.STLTHRecorder.io", qos: .userInitiated)
    private let lock = NSLock()
    private var isRunning = false
    /// Latched by `stop()` so an in-flight rebuild cannot resurrect the graph.
    private var isStopped = false

    /// Extra processes kept out of the system tap, by pid.
    ///
    /// Empty in the product: a global tap is meant to catch everything the Mac plays.
    /// The bench needs it because the advisor has no microphone here — their voice is
    /// synthesised and pushed into the loopback by a *separate process*, and a global
    /// tap picks that up too, so the same voice lands in both tracks and channel
    /// separation cannot be demonstrated. Excluding the player restores the real
    /// topology, where the advisor's voice exists only as microphone input.
    private let extraExcludedProcesses: [pid_t]

    public init(sessionDir: URL, excludingFromTap extraExcludedProcesses: [pid_t] = []) {
        self.sessionDir = sessionDir
        self.extraExcludedProcesses = extraExcludedProcesses
    }

    deinit {
        teardownCoreAudio()
    }

    // MARK: - Start

    public func start() throws {
        guard !isRunning else { throw AudioEngineError.alreadyRunning }

        try openWriters()

        lock.lock()
        // Anchor both timelines to the session's own start. A tap delivers nothing
        // until some process plays, so without this anchor a meeting that begins in
        // silence would simply be missing from the front of the file.
        let startedAt = CoreAudioSupport.seconds(fromHostTime: mach_absolute_time())
        micTimeline.start(at: startedAt)
        systemTimeline.start(at: startedAt)
        isRunning = true
        lock.unlock()

        try buildCaptureGraph()
        startWatchingDevices()
        startWatchdog()
    }

    /// Create the tap and the aggregate around whatever the current default devices
    /// are, and get IO running.
    ///
    /// Split out from `start()` because a device change mid-meeting has to do exactly
    /// the same thing again — the graph is rebuilt around the new devices while the
    /// writers, and therefore the timeline, carry on untouched.
    private func buildCaptureGraph() throws {
        let outputDeviceID = try CoreAudioSupport.defaultOutputDevice()
        guard outputDeviceID != AudioObjectID(kAudioObjectUnknown) else {
            throw AudioEngineError.noSystemOutput
        }
        outputDeviceName = CoreAudioSupport.deviceName(outputDeviceID)

        let inputDeviceID = CoreAudioSupport.defaultInputDevice()
        let hasInput = inputDeviceID != AudioObjectID(kAudioObjectUnknown)
        inputDeviceName = hasInput ? CoreAudioSupport.deviceName(inputDeviceID) : "Немає мікрофона"

        try createTap()
        let tapASBD = try readTapFormat()

        guard hasInput else {
            try bringUpAggregate(tapASBD: tapASBD, outputDeviceID: outputDeviceID, inputDeviceID: nil)
            captureMode = .systemOnly
            logStarted()
            return
        }

        // The preferred layout — microphone and tap in one aggregate — is what makes
        // the two tracks share a clock. Everything below is what happens when this
        // machine will not bring it up.
        //
        // Note what is deliberately *not* a failure signal here: an aggregate that
        // delivers no callbacks yet. A process tap only runs while some process is
        // actually playing, so a meeting that starts in silence legitimately produces
        // nothing for a while. Treating that as a failure would quietly demote a
        // perfectly good single-clock capture on every quiet start.
        do {
            try bringUpAggregate(tapASBD: tapASBD,
                                 outputDeviceID: outputDeviceID,
                                 inputDeviceID: inputDeviceID)
            captureMode = .singleAggregate
            logStarted()
            return
        } catch AudioEngineError.setupTimedOut(let call) {
            logger.warning("\(call, privacy: .public) did not return — abandoning the microphone aggregate")
        }

        try restartWithoutInputDevice(outputDeviceID: outputDeviceID, afterTimeout: true)
        startMicrophoneFallback()
        captureMode = .splitClock
        logStarted()
    }

    // MARK: - Device changes

    /// Rebuild the capture graph when the advisor switches devices mid-meeting —
    /// plugging in AirPods is the everyday case (spec §4).
    private func startWatchingDevices() {
        deviceMonitor.onDefaultInputChanged = { [weak self] name in
            self?.deviceChanged(input: name, output: nil)
        }
        deviceMonitor.onDefaultOutputChanged = { [weak self] name in
            self?.deviceChanged(input: nil, output: name)
        }
        deviceMonitor.start()
    }

    /// Poll for a stalled capture graph once a second.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.checkForStall() }
        watchdogTimer = timer
        timer.resume()
    }

    private func checkForStall() {
        lock.lock()
        let running = isRunning && !isStopped
        let everReceived = hasEverReceivedCallback
        let since = CoreAudioSupport.seconds(fromHostTime: mach_absolute_time()) - lastCallbackAt
        let aggregate = aggregateID
        lock.unlock()

        guard running, aggregate != AudioObjectID(kAudioObjectUnknown) else { return }

        let runningFlag: UInt32? = try? CoreAudioSupport.property(aggregate,
                                                                  kAudioDevicePropertyDeviceIsRunning,
                                                                  UInt32(0))
        let deviceRunning = (runningFlag ?? 0) != 0

        guard Self.shouldRebuild(hasEverReceivedCallback: everReceived,
                                 secondsSinceLastCallback: since,
                                 deviceReportsRunning: deviceRunning) else { return }

        logger.warning("Capture stalled: device reports running but no callbacks for \(since, format: .fixed(precision: 1)) s — rebuilding")
        rebuildCaptureGraph()
    }

    private func deviceChanged(input: String?, output: String?) {
        lock.lock()
        guard isRunning, !isStopped else { lock.unlock(); return }
        deviceChanges.append(SessionMeta.DeviceChange(at: Date(), input: input, output: output))
        lock.unlock()

        // The listener fires on the main queue; rebuilding there would block the UI
        // for as long as CoreAudio takes. The serial control queue also guarantees
        // that two changes in quick succession cannot rebuild on top of each other.
        controlQueue.async { [weak self] in self?.rebuildCaptureGraph() }
    }

    private func rebuildCaptureGraph() {
        lock.lock()
        guard isRunning, !isStopped else { lock.unlock(); return }
        // Callbacks are dropped while the graph is down; the resulting gap is padded
        // by the timeline accountant, so the tracks keep their wall-clock length.
        isRunning = false
        lock.unlock()

        stopMicrophoneFallback()
        teardownCoreAudio()

        // The user may have pressed stop while we were tearing the graph down. Coming
        // back up now would leave a tap and an aggregate alive that `stop()` has
        // already walked past — nothing would ever destroy them.
        lock.lock()
        guard !isStopped else { lock.unlock(); return }
        layoutResolved = false
        micBufferIndex = nil
        systemBufferIndex = nil
        isRunning = true
        lock.unlock()

        do {
            try buildCaptureGraph()
        } catch {
            // Recording continues as silence rather than dying: the files stay the
            // right length and the failure is visible in meta.json and the log.
            logger.error("Rebuild after a device change failed: \(error.localizedDescription, privacy: .public)")
        }

        // And it may have happened while we were building. Clean up after ourselves
        // rather than making stop() wait for a rebuild it never asked for.
        lock.lock()
        let stoppedMeanwhile = isStopped
        if stoppedMeanwhile { isRunning = false }
        lock.unlock()
        if stoppedMeanwhile {
            stopMicrophoneFallback()
            teardownCoreAudio()
        }
    }

    private func logStarted() {
        logger.info("""
            Recording started in \(self.captureMode.rawValue, privacy: .public) mode: \
            input=\(self.inputDeviceName, privacy: .public), \
            output=\(self.outputDeviceName, privacy: .public)
            """)
    }

    /// Build the aggregate and get IO running — under a deadline.
    ///
    /// `AudioDeviceCreateIOProcIDWithBlock` does **not** return while the microphone's
    /// TCC decision is still pending: it parks in a `mach_msg` to `coreaudiod` and
    /// stays there (reproduced on the bench with `Tools/deadlock-probe`). `start()` is
    /// called from the main actor, so an unbounded wait there freezes the menu bar —
    /// the app would look hung with no way out. Hence the deadline: we would rather
    /// record on a degraded path than not respond at all.
    private func bringUpAggregate(tapASBD: AudioStreamBasicDescription,
                                  outputDeviceID: AudioDeviceID,
                                  inputDeviceID: AudioDeviceID?) throws {
        let failure = ErrorBox()
        let finished = withDeadline(Self.setupDeadline) { [self] in
            do {
                try createAggregate(outputDeviceID: outputDeviceID, inputDeviceID: inputDeviceID)
                resolveBufferLayout(tapChannels: tapASBD.mChannelsPerFrame,
                                    hasInput: inputDeviceID != nil)
                try startIO(tapASBD: tapASBD)
            } catch {
                failure.error = error
            }
        }
        guard finished else { throw AudioEngineError.setupTimedOut("aggregate setup") }
        if let error = failure.error { throw error }
    }

    /// Run `work` on its own thread and stop waiting after `seconds`.
    ///
    /// A CoreAudio call blocked in `mach_msg` cannot be cancelled or interrupted, so
    /// the thread is abandoned rather than stopped. That leak is deliberate and
    /// bounded: it costs one parked thread until the process exits, and it buys back
    /// a responsive UI.
    private func withDeadline(_ seconds: TimeInterval, _ work: @escaping () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            work()
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        return done.wait(timeout: .now() + seconds) == .success
    }

    private func createTap() throws {
        let ownProcess = CoreAudioSupport.currentProcessObjectID()
        var excluded: [AudioObjectID] = ownProcess == AudioObjectID(kAudioObjectUnknown) ? [] : [ownProcess]
        excluded.append(contentsOf: extraExcludedProcesses.compactMap {
            let id = CoreAudioSupport.processObjectID(forPID: $0)
            return id == AudioObjectID(kAudioObjectUnknown) ? nil : id
        })

        // Global tap = every process except ours. Platform independence (Zoom, Meet,
        // an in-person meeting through the speakers) comes for free — ТЗ F-1/F-2.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        tapUUID = UUID()
        description.uuid = tapUUID
        description.name = "STLTHRecorderSystemTap"
        description.isPrivate = true
        // Must stay unmuted: the advisor has to keep hearing the client.
        description.muteBehavior = CATapMuteBehavior.unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else {
            throw AudioEngineError.coreAudio("AudioHardwareCreateProcessTap", status)
        }
        tapID = newTapID
    }

    /// Read the tap's stream format, retrying briefly.
    ///
    /// A freshly created tap does not describe itself immediately — most visibly on
    /// the very first run, where the system-audio permission is granted *while* the
    /// tap is being set up. The first read then fails and the app reports "не вдалося
    /// почати запис" on the one attempt a new user makes.
    private func readTapFormat() throws -> AudioStreamBasicDescription {
        let deadline = Date().addingTimeInterval(2)
        var lastAttempt: AudioStreamBasicDescription?
        repeat {
            if let asbd = try? CoreAudioSupport.property(tapID, kAudioTapPropertyFormat,
                                                         AudioStreamBasicDescription()),
               asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 {
                return asbd
            }
            lastAttempt = nil
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        _ = lastAttempt
        throw AudioEngineError.tapFormatUnavailable
    }

    private func createAggregate(outputDeviceID: AudioDeviceID, inputDeviceID: AudioDeviceID?) throws {
        let outputUID = try CoreAudioSupport.deviceUID(outputDeviceID)

        // Sub-device order defines callback buffer order, so the mic goes first and
        // the tap's buffers follow.
        var subDevices: [[String: Any]] = []
        var inputIsSeparateDevice = false
        if let inputDeviceID, let inputUID = try? CoreAudioSupport.deviceUID(inputDeviceID),
           inputUID != outputUID {
            // A headset that is both input and output shares one UID; listing it twice
            // produces an aggregate that never starts (zero IO callbacks).
            subDevices.append([
                kAudioSubDeviceUIDKey: inputUID,
                kAudioSubDeviceDriftCompensationKey: true,
            ])
            inputIsSeparateDevice = true
        }
        subDevices.append([kAudioSubDeviceUIDKey: outputUID])
        self.inputSharesOutputDevice = inputDeviceID != nil && !inputIsSeparateDevice

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "STLTHRecorderAggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                // The tap *description's* UUID, not the tap object ID — see findings §3.1.
                kAudioSubTapUIDKey: tapUUID.uuidString,
            ]],
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard status == noErr else {
            throw AudioEngineError.coreAudio("AudioHardwareCreateAggregateDevice", status)
        }
        aggregateID = newAggregateID
    }

    /// Log the layout the aggregate *claims* to have.
    ///
    /// Only diagnostics: right after creation the aggregate often reports an empty
    /// stream configuration, so the real mapping is resolved from the first callback
    /// (`resolveLayoutIfNeeded`) rather than from this property.
    private func resolveBufferLayout(tapChannels: UInt32, hasInput: Bool) {
        let layout = CoreAudioSupport.inputChannelLayout(aggregateID)
        self.hasInputDevice = hasInput
        logger.info("Aggregate reports input layout \(layout, privacy: .public); tap has \(tapChannels) ch")
    }

    /// Map callback buffers to tracks using the buffer list we actually got.
    ///
    /// Sub-devices come first in aggregate callback order, taps last — and an
    /// output-only sub-device contributes no input buffer at all, which is why the
    /// index cannot be assumed ahead of time.
    private func resolveLayoutIfNeeded(_ buffers: UnsafeMutableAudioBufferListPointer) {
        guard !layoutResolved else { return }
        layoutResolved = true

        let shape = buffers.map { "\($0.mNumberChannels)ch" }.joined(separator: "+")
        logger.info("First callback buffer shape: \(shape, privacy: .public)")

        guard !buffers.isEmpty else { return }

        // The tap is always the last buffer.
        systemBufferIndex = buffers.count - 1

        if hasInputDevice && buffers.count >= 2 {
            micBufferIndex = 0
            micChannelCount = buffers[0].mNumberChannels
        } else {
            // No microphone on this machine (cloud bench): mic.caf is written as
            // honest silence so the timeline invariant still holds.
            micBufferIndex = nil
        }
    }

    private func openWriters() throws {
        micWriter = try CAFWriter(url: sessionDir.appendingPathComponent("mic.caf"), channels: 1)
        systemWriter = try CAFWriter(url: sessionDir.appendingPathComponent("system.caf"), channels: 2)
        micTimeline = TimelineAccountant(sampleRate: 48000)
        systemTimeline = TimelineAccountant(sampleRate: 48000)
    }

    private func startIO(tapASBD: AudioStreamBasicDescription) throws {
        var asbd = tapASBD
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw AudioEngineError.tapFormatUnavailable
        }
        tapFormat = format

        var newProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, ioQueue) {
            [weak self] _, inInputData, inInputTime, _, _ in
            self?.handle(inputData: inInputData, time: inInputTime)
        }
        guard createStatus == noErr, let newProcID else {
            throw AudioEngineError.coreAudio("AudioDeviceCreateIOProcIDWithBlock", createStatus)
        }
        procID = newProcID

        let startStatus = AudioDeviceStart(aggregateID, newProcID)
        guard startStatus == noErr else {
            throw AudioEngineError.coreAudio("AudioDeviceStart", startStatus)
        }
    }

    // MARK: - Fallback path

    /// Rebuild the aggregate with the tap alone — the configuration that is known to
    /// run everywhere — leaving the microphone to its own engine.
    ///
    /// - Parameter afterTimeout: the previous attempt never returned, so a thread is
    ///   still parked inside CoreAudio holding those objects. Tearing them down from
    ///   here would block us on the same lock, so they are abandoned instead.
    private func restartWithoutInputDevice(outputDeviceID: AudioDeviceID,
                                           afterTimeout: Bool) throws {
        lock.lock()
        isRunning = false
        lock.unlock()

        if afterTimeout {
            abandonCoreAudioObjects()
        } else {
            teardownCoreAudio()
        }

        try createTap()
        let tapASBD = try readTapFormat()

        lock.lock()
        layoutResolved = false
        micBufferIndex = nil
        systemBufferIndex = nil
        hasInputDevice = false
        callbackCount = 0
        isRunning = true
        lock.unlock()

        try bringUpAggregate(tapASBD: tapASBD, outputDeviceID: outputDeviceID, inputDeviceID: nil)
    }

    /// Let go of CoreAudio objects we can no longer safely touch.
    ///
    /// The strays are freed when the process exits; the alternative — calling
    /// `AudioHardwareDestroyAggregateDevice` on an object another thread is stuck
    /// inside — is how a "graceful" cleanup turns into a second hang.
    private func abandonCoreAudioObjects() {
        logger.warning("Abandoning aggregate \(self.aggregateID) and tap \(self.tapID) — a thread is still blocked inside CoreAudio")
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        procID = nil
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Capture the microphone with its own CoreAudio IO proc.
    ///
    /// Deliberately not AVAudioEngine: `inputNode` raises an Objective-C exception on
    /// devices it dislikes, and Swift cannot catch that — the process just dies. A raw
    /// IO proc returns an OSStatus we can handle.
    ///
    /// This is the compromise of the fallback: the mic now runs on its own clock, so
    /// the tracks are aligned by the timeline invariant (each buffer padded to its
    /// wall-clock position) rather than by shared hardware timing.
    private func startMicrophoneFallback() {
        let deviceID = CoreAudioSupport.defaultInputDevice()
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else { return }

        var format = AudioStreamBasicDescription()
        guard let asbd = try? CoreAudioSupport.property(deviceID, kAudioDevicePropertyStreamFormat,
                                                        AudioStreamBasicDescription(),
                                                        scope: kAudioObjectPropertyScopeInput) else {
            logger.error("Fallback mic: cannot read stream format")
            return
        }
        format = asbd
        micFallbackSampleRate = format.mSampleRate > 0 ? format.mSampleRate : CAFWriter.sampleRate
        if abs(micFallbackSampleRate - CAFWriter.sampleRate) > 1 {
            logger.warning("Fallback mic runs at \(self.micFallbackSampleRate) Hz, not 48000")
        }

        var newProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, deviceID, micQueue) {
            [weak self] _, inInputData, inInputTime, _, _ in
            self?.handleMicrophone(inputData: inInputData, time: inInputTime)
        }
        guard createStatus == noErr, let newProcID else {
            logger.error("Fallback mic: create IO proc failed \(createStatus)")
            return
        }

        let startStatus = AudioDeviceStart(deviceID, newProcID)
        guard startStatus == noErr else {
            logger.error("Fallback mic: AudioDeviceStart failed \(startStatus)")
            AudioDeviceDestroyIOProcID(deviceID, newProcID)
            return
        }

        micDeviceID = deviceID
        micProcID = newProcID
        logger.info("Fallback microphone started on device \(deviceID) at \(self.micFallbackSampleRate) Hz")
    }

    private func handleMicrophone(inputData: UnsafePointer<AudioBufferList>,
                                  time: UnsafePointer<AudioTimeStamp>) {
        let timestamp = CoreAudioSupport.seconds(fromHostTime: time.pointee.mHostTime)
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))

        lock.lock()
        defer { lock.unlock() }
        guard isRunning, let writer = micWriter, let buffer = buffers.first else { return }

        micCallbackCount += 1
        write(buffer: buffer, to: writer, timeline: &micTimeline,
              timestamp: timestamp, channels: 1)
    }

    private func stopMicrophoneFallback() {
        guard let micProcID, micDeviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        AudioDeviceStop(micDeviceID, micProcID)
        AudioDeviceDestroyIOProcID(micDeviceID, micProcID)
        self.micProcID = nil
        micDeviceID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - IO callback

    private func handle(inputData: UnsafePointer<AudioBufferList>,
                        time: UnsafePointer<AudioTimeStamp>) {
        let timestamp = CoreAudioSupport.seconds(fromHostTime: time.pointee.mHostTime)
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )

        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }

        callbackCount += 1
        hasEverReceivedCallback = true
        lastCallbackAt = CoreAudioSupport.seconds(fromHostTime: mach_absolute_time())
        resolveLayoutIfNeeded(buffers)

        // System track (client).
        if let index = systemBufferIndex, index < buffers.count {
            noteSystemAudio(in: buffers[index])
            write(buffer: buffers[index], to: systemWriter, timeline: &systemTimeline,
                  timestamp: timestamp, channels: 2)
        }

        // Mic track (advisor). Absent on a machine with no audio input — the track is
        // still written, as silence, so the timeline invariant holds either way.
        if let index = micBufferIndex, index < buffers.count {
            write(buffer: buffers[index], to: micWriter, timeline: &micTimeline,
                  timestamp: timestamp, channels: 1)
        } else if micProcID == nil, let systemIndex = systemBufferIndex, systemIndex < buffers.count {
            // No mic source at all: keep the track growing so both files stay the same
            // length. Skipped in split-clock mode, where the fallback engine writes it.
            let frames = frameCount(of: buffers[systemIndex])
            padOnly(writer: micWriter, timeline: &micTimeline, timestamp: timestamp, frames: frames)
        }
    }

    private func frameCount(of buffer: AudioBuffer) -> Int {
        let channels = max(1, Int(buffer.mNumberChannels))
        return Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
    }

    private func write(buffer: AudioBuffer,
                       to writer: CAFWriter?,
                       timeline: inout TimelineAccountant,
                       timestamp: Double,
                       channels: AVAudioChannelCount) {
        guard let writer, let data = buffer.mData else { return }
        let frames = frameCount(of: buffer)
        guard frames > 0 else { return }

        let padding = timeline.frames(toInsertBefore: timestamp, frameCount: frames)
        do {
            if padding > 0 { try writer.writeSilence(frames: padding) }

            guard let format = AVAudioFormat(standardFormatWithSampleRate: CAFWriter.sampleRate,
                                             channels: channels),
                  let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(frames)) else { return }
            pcm.frameLength = AVAudioFrameCount(frames)

            let source = data.bindMemory(to: Float.self,
                                         capacity: frames * Int(buffer.mNumberChannels))
            let sourceChannels = Int(buffer.mNumberChannels)

            // Callback buffers are interleaved; our processing format is not.
            for channel in 0..<Int(channels) {
                let destination = pcm.floatChannelData![channel]
                let sourceChannel = min(channel, sourceChannels - 1)
                for frame in 0..<frames {
                    destination[frame] = source[frame * sourceChannels + sourceChannel]
                }
            }
            try writer.write(pcm)
        } catch {
            logger.error("Write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Keep a track's timeline advancing when it has no source of its own.
    private func padOnly(writer: CAFWriter?,
                         timeline: inout TimelineAccountant,
                         timestamp: Double,
                         frames: Int) {
        guard let writer, frames > 0 else { return }
        let padding = timeline.frames(toInsertBefore: timestamp, frameCount: frames)
        do {
            try writer.writeSilence(frames: padding + frames)
        } catch {
            logger.error("Silence write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Fill a track with silence up to the session's stop time.
    private func padToEnd(writer: CAFWriter?, timeline: inout TimelineAccountant, end: Double) {
        guard let writer else { return }
        let padding = timeline.frames(toReach: end)
        guard padding > 0 else { return }
        do {
            try writer.writeSilence(frames: padding)
        } catch {
            logger.error("Tail silence write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Stop

    public func stop() -> RecordingResult {
        watchdogTimer?.cancel()
        watchdogTimer = nil
        deviceMonitor.stop()
        lock.lock()
        // Latched before anything else: a rebuild may already be in flight on the
        // control queue, and this is what tells it to stand down instead of bringing
        // a fresh tap up behind our back.
        isStopped = true
        lock.unlock()

        stopMicrophoneFallback()

        lock.lock()
        isRunning = false
        // Carry both tracks up to the moment we stopped, so the session's own length
        // — not the last buffer that happened to arrive — decides the file length.
        let stoppedAt = CoreAudioSupport.seconds(fromHostTime: mach_absolute_time())
        padToEnd(writer: micWriter, timeline: &micTimeline, end: stoppedAt)
        padToEnd(writer: systemWriter, timeline: &systemTimeline, end: stoppedAt)
        let micFrames = micWriter?.framesWritten ?? 0
        let systemFrames = systemWriter?.framesWritten ?? 0
        lock.unlock()

        teardownCoreAudio()

        // Closing the files is what flushes them to disk.
        micWriter = nil
        systemWriter = nil

        // Duration is the longer track: both are padded to the same length, and the
        // longer one is the honest wall-clock length of the session.
        let frames = max(micFrames, systemFrames)
        let durationMs = Int((Double(frames) / CAFWriter.sampleRate * 1000).rounded())

        logger.info("Recording stopped: \(frames) frames (\(durationMs) ms)")

        return RecordingResult(
            micURL: sessionDir.appendingPathComponent("mic.caf"),
            systemURL: sessionDir.appendingPathComponent("system.caf"),
            durationMs: durationMs,
            inputDeviceName: inputDeviceName,
            outputDeviceName: outputDeviceName,
            captureMode: captureMode,
            deviceChanges: deviceChanges,
            systemAudioDetected: systemAudioDetected
        )
    }

    /// Teardown order matters and mirrors AudioCap's `invalidate()`:
    /// stop IO → destroy IO proc → destroy aggregate → destroy tap.
    private func teardownCoreAudio() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
                self.procID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
