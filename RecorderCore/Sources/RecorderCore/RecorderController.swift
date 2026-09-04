import Combine
import Foundation

/// What the controller needs from a capture engine. The real implementation is
/// `AudioEngine`; tests substitute a mock so the state machine can be verified
/// without audio hardware.
public protocol AudioEngineProtocol: AnyObject {
    func start() throws
    func stop() -> RecordingResult
}

/// The app's single state machine: `idle → preparing → recording → stopping → idle`.
///
/// Transitions are guarded, which is what satisfies the ТЗ requirement that tapping
/// "Почати запис" twice never creates a duplicate session or breaks the app (F-1).
@MainActor
public final class RecorderController: ObservableObject {

    public enum State: Equatable {
        case idle
        case preparing
        case recording(started: Date)
        case stopping
    }

    @Published public private(set) var state: State = .idle
    /// Last failure, in Ukrainian, ready to be shown in the menu.
    @Published public private(set) var lastError: String?
    /// Outcome of the session that just finished — the UI reads it to learn whether
    /// system audio actually arrived.
    @Published public private(set) var lastResult: RecordingResult?
    /// Metadata of the session that just finished — what the mixdown is built from.
    @Published public private(set) var lastCompletedMeta: SessionMeta?

    public let store: SessionStore
    private let engineFactory: (URL) throws -> AudioEngineProtocol

    private var engine: AudioEngineProtocol?
    private var handle: SessionHandle?
    /// Drives the menu-bar clock: `elapsed` is computed, so SwiftUI needs a nudge
    /// to re-read it while a recording is running.
    private var tickTimer: Timer?

    public init(store: SessionStore,
                engineFactory: @escaping (URL) throws -> AudioEngineProtocol) {
        self.store = store
        self.engineFactory = engineFactory
    }

    /// Seconds since the current recording started; 0 when not recording.
    public var elapsed: TimeInterval {
        guard case .recording(let started) = state else { return 0 }
        return Date().timeIntervalSince(started)
    }

    public var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    // MARK: - Actions

    /// Begin a session. Ignored unless idle — that guard *is* the duplicate protection.
    ///
    /// - Parameter consentAt: when the advisor confirmed the client's consent (F-4).
    public func startTapped(consentAt: Date) {
        guard state == .idle else { return }
        state = .preparing
        lastError = nil

        var startedHandle: SessionHandle?
        do {
            let handle = try store.begin(consentAt: consentAt)
            startedHandle = handle
            let engine = try engineFactory(handle.dir)
            try engine.start()

            self.handle = handle
            self.engine = engine
            state = .recording(started: Date())
            startTicking()
        } catch {
            // Whatever was already on disk stays on disk and is marked honestly.
            if let startedHandle {
                try? store.interrupt(startedHandle)
            }
            self.handle = nil
            self.engine = nil
            lastError = "Не вдалося почати запис: \(error.localizedDescription)"
            state = .idle
        }
    }

    /// Stop and finalise the session. Ignored unless recording.
    public func stopTapped() {
        guard case .recording = state, let engine, let handle else { return }
        state = .stopping

        stopTicking()

        let result = engine.stop()
        lastResult = result
        do {
            try store.complete(handle, result: result)
            lastCompletedMeta = try? SessionMeta.load(
                from: handle.dir.appendingPathComponent("meta.json"))
        } catch {
            lastError = "Запис зупинено, але не вдалося оновити meta.json: \(error.localizedDescription)"
        }

        self.engine = nil
        self.handle = nil
        state = .idle
    }

    /// Recover sessions left behind by a crash — called at app launch (spec §4).
    ///
    /// The repaired directories are kept so anything derived from them — the listening
    /// mixdown — can be rebuilt once the app layer has decided whether it wants to.
    public func recoverInterruptedSessions() {
        recoveredSessions = store.recoverInterrupted()
    }

    /// Directories repaired at launch, for the caller to rebuild derivatives from.
    @Published public private(set) var recoveredSessions: [URL] = []

    // MARK: - Menu-bar clock

    private func startTicking() {
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.objectWillChange.send()
            }
        }
        RunLoop.main.add(timer, forMode: .common) // keeps ticking while a menu is open
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }
}
