import Combine
import CryptoKit
import Foundation
import OSLog

/// Fetches the two models transcription needs, so the advisor never opens a terminal.
///
/// The models stay out of the bundle for the reason README gives: half a gigabyte in a
/// recorder whose core job does not need it. What went wrong was the *replacement* —
/// the app told the user to run `scripts/setup-transcription.sh`, and a machine that
/// installed the DMG has no `scripts/` directory. An instruction pointing at a file the
/// user does not have is not an installer, and the menu item that carried it was not
/// even a button.
///
/// Design note: `docs/design/specs/2026-08-10-transcription-setup.md`.
@MainActor
public final class ModelInstaller: ObservableObject {

    nonisolated private static let logger = Logger(subsystem: "ua.stlth.STLTHRecorder", category: "ModelInstaller")

    /// One downloadable file, pinned by size *and* digest.
    ///
    /// Pinning matters more than it looks: HuggingFace answers a bad path with an HTML
    /// error page, and a 3 KB page saved as `ggml-large-v3-q5_0.bin` fails later,
    /// deep inside whisper, as something unrecognisable. The shell script leans on
    /// `curl -f` for this; here the digest does the same job and also catches a
    /// truncated download that `-f` would happily keep.
    public struct Model: Sendable, Equatable {
        public let name: String
        public let url: URL
        public let bytes: Int64
        public let sha256: String
        /// What this file is for, in the user's words.
        public let purpose: String
    }

    public enum State: Equatable {
        case notInstalled
        /// `completed` and `total` count bytes across *all* models, so one progress bar
        /// covers the whole job rather than resetting between files.
        case downloading(file: String, completed: Int64, total: Int64)
        case ready
        case failed(String)
    }

    public enum InstallerError: LocalizedError, Equatable {
        case http(Int)
        case checksumMismatch(String)
        case truncated(String, Int64, Int64)
        case noSpace(Int64)

        public var errorDescription: String? {
            switch self {
            case .http(let code):
                return "Сервер моделей відповів помилкою \(code). Спробуйте пізніше."
            case .checksumMismatch(let name):
                return "Файл \(name) завантажився пошкодженим і був відкинутий. Спробуйте ще раз."
            case .truncated(let name, let got, let want):
                return "Файл \(name) завантажився не повністю (\(got) з \(want) байтів)."
            case .noSpace(let need):
                let formatted = ByteCountFormatter.string(fromByteCount: need, countStyle: .file)
                return "Недостатньо місця: потрібно щонайменше \(formatted) вільних."
            }
        }
    }

    // MARK: - What gets downloaded

    /// Both files are required. Without the VAD model whisper invents sentences in
    /// silence — and a meeting is mostly silence — so shipping speech recognition
    /// without it would make the feature worse than absent.
    ///
    /// Sizes and digests: the speech model measured 2026-09-04 by downloading the file
    /// in full and hashing it (it also matches HuggingFace's LFS `X-Linked-ETag`); the
    /// VAD model measured 2026-08-10 the same way.
    nonisolated public static let requiredModels: [Model] = [
        // Full large-v3, not turbo. Turbo is twice as fast because its decoder is
        // distilled from 32 layers to 4 — and the decoder is what turns tokens into a
        // sentence that holds together. The Windows build of this product observed
        // it directly on Ukrainian: turbo produced «Тораз глянемо» where the full
        // model hears «Та розглянемо», and fragments where it hears words.
        // Transcription is a background job after the call, so twice the time costs
        // less than mangled lines. No WER was measured for this model on this bench;
        // every number in ENGINEERING_NOTES §10 is turbo's.
        Model(name: "ggml-large-v3-q5_0.bin",
              url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin")!,
              bytes: 1_081_140_203,
              sha256: "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1",
              purpose: "розпізнавання мовлення"),
        Model(name: "ggml-silero-v5.1.2.bin",
              url: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!,
              bytes: 885_098,
              sha256: "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf",
              purpose: "виявлення мовлення (VAD)"),
    ]

    /// Models an earlier version installed and this one no longer fetches. Leaving them
    /// in place means keeping half a gigabyte nobody will open again — but they go
    /// only once their replacement has downloaded and verified, so a dropped download
    /// never leaves the user with no working model at all. Until then `Transcriber`
    /// still lists them as candidates, and a machine that has not re-downloaded keeps
    /// transcribing on the old file.
    nonisolated public static let supersededModels = ["ggml-large-v3-turbo-q5_0.bin"]

    nonisolated static func removeSuperseded(in directory: URL) {
        for name in supersededModels {
            let file = directory.appendingPathComponent(name)
            // Busy or unreadable: it simply stays. Not worth failing an install over.
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.appendingPathExtension("part"))
        }
    }

    /// The directory `Transcriber` already searches first, and the one the shell script
    /// writes to — so a machine set up either way ends up in the same place.
    nonisolated public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("STLTHRecorder/Models", isDirectory: true)
    }

    /// Total download, for the sentence the user reads before agreeing to it.
    nonisolated public static var totalBytes: Int64 { requiredModels.reduce(0) { $0 + $1.bytes } }

    // MARK: - Lifecycle

    public typealias Fetch = @Sendable (_ url: URL,
                                        _ offset: Int64,
                                        _ sink: @Sendable @escaping (Data) -> Void) async throws -> Void

    @Published public private(set) var state: State = .notInstalled

    public let directory: URL
    private let fetch: Fetch
    private var job: Task<Void, Never>?

    public init(directory: URL = ModelInstaller.defaultDirectory,
                fetch: @escaping Fetch = ModelInstaller.httpFetch) {
        self.directory = directory
        self.fetch = fetch
        self.state = Self.isInstalled(in: directory) ? .ready : .notInstalled
    }

    // MARK: - Inspection

    nonisolated public static func isInstalled(in directory: URL) -> Bool {
        requiredModels.allSatisfy { isPresent($0, in: directory) }
    }

    /// A model counts as present only at its exact size. A half-finished file left by a
    /// killed download must not read as "installed" — that is how you get a feature that
    /// looks available and fails at the moment it is used.
    nonisolated static func isPresent(_ model: Model, in directory: URL) -> Bool {
        size(of: directory.appendingPathComponent(model.name)) == model.bytes
    }

    /// Bytes on disk, so Settings can say what deleting them would free.
    nonisolated public static func installedBytes(in directory: URL) -> Int64 {
        requiredModels.reduce(0) { $0 + size(of: directory.appendingPathComponent($1.name)) }
    }

    public var isInstalled: Bool { Self.isInstalled(in: directory) }

    public func refresh() {
        guard job == nil else { return }
        state = isInstalled ? .ready : .notInstalled
    }

    // MARK: - Install

    /// Never starts on its own. 548 MB of silent traffic from an app that promises
    /// everything stays on this Mac is precisely what a user would not forgive.
    public func install() {
        guard job == nil else { return }

        let free = DiskGuard.freeBytes(at: directory.deletingLastPathComponent())
        let needed = Self.totalBytes - Self.installedBytes(in: directory)
        guard free > needed + 200_000_000 else {
            state = .failed(InstallerError.noSpace(needed).localizedDescription)
            return
        }

        state = .downloading(file: Self.requiredModels[0].name,
                             completed: Self.installedBytes(in: directory),
                             total: Self.totalBytes)

        let directory = self.directory
        let fetch = self.fetch

        job = Task.detached(priority: .utility) { [weak self] in
            let result: Result<Void, Error>
            do {
                try await Self.downloadAll(into: directory, fetch: fetch) { file, completed in
                    await MainActor.run { [weak self] in
                        guard let self, self.job != nil else { return }
                        self.state = .downloading(file: file, completed: completed, total: Self.totalBytes)
                    }
                }
                result = .success(())
            } catch {
                result = .failure(error)
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.job = nil
                switch result {
                case .success:
                    self.state = .ready
                    Self.logger.info("Transcription models installed")
                case .failure(let error):
                    if error is CancellationError {
                        // The part files stay: cancelling should cost the user nothing
                        // but time already spent, and the next attempt resumes.
                        self.state = self.isInstalled ? .ready : .notInstalled
                    } else {
                        self.state = .failed(error.localizedDescription)
                        Self.logger.error("Model download failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    /// Stops the download and leaves the partial file in place for the next attempt.
    public func cancel() {
        job?.cancel()
        job = nil
        state = isInstalled ? .ready : .notInstalled
    }

    /// Frees the gigabyte again. Partial downloads go too — leaving them would be the
    /// one case where "deleted" does not free what Settings said it would — and so
    /// does a model left over from an earlier version, for the same reason.
    public func removeModels() throws {
        cancel()
        for model in Self.requiredModels {
            let file = directory.appendingPathComponent(model.name)
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.appendingPathExtension("part"))
        }
        Self.removeSuperseded(in: directory)
        state = .notInstalled
    }

    // MARK: - Downloading

    /// - Parameter models: `requiredModels` in production; tests pass stand-ins so the
    ///   ordering around `removeSuperseded` can be checked without a gigabyte.
    nonisolated static func downloadAll(into directory: URL,
                                        models: [Model] = requiredModels,
                                        fetch: Fetch,
                                        progress: @escaping @Sendable (String, Int64) async -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var completed: Int64 = 0
        for model in models {
            if isPresent(model, in: directory) {
                completed += model.bytes
                continue
            }
            try await download(model, into: directory, fetch: fetch, baseline: completed, progress: progress)
            completed += model.bytes
        }
        // Reached only when every model above is on disk and verified — a throw skips
        // this on purpose, so a failed replacement never takes the old model with it.
        removeSuperseded(in: directory)
    }

    nonisolated static func download(_ model: Model,
                         into directory: URL,
                         fetch: Fetch,
                         baseline: Int64,
                         progress: @escaping @Sendable (String, Int64) async -> Void) async throws {
        let target = directory.appendingPathComponent(model.name)
        let part = target.appendingPathExtension("part")

        // Resume where the last attempt stopped. 548 MB over a hotel connection is not
        // something to restart from zero because a lid closed.
        var offset = size(of: part)
        if offset > model.bytes {
            try? FileManager.default.removeItem(at: part)
            offset = 0
        }
        if offset == 0 {
            FileManager.default.createFile(atPath: part.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        try handle.seekToEnd()

        let written = Counter(offset)
        try await fetch(model.url, offset) { chunk in
            try? handle.write(contentsOf: chunk)
            let total = written.add(Int64(chunk.count))
            // Reporting every chunk would hop to the main actor thousands of times a
            // second for no visible difference; a megabyte is one pixel of progress.
            if written.shouldReport() {
                Task { await progress(model.name, baseline + total) }
            }
        }
        try handle.close()

        let got = size(of: part)
        guard got == model.bytes else {
            throw InstallerError.truncated(model.name, got, model.bytes)
        }
        guard try digest(of: part) == model.sha256 else {
            try? FileManager.default.removeItem(at: part)
            throw InstallerError.checksumMismatch(model.name)
        }

        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: part, to: target)
        await progress(model.name, baseline + model.bytes)
    }

    /// HTTP with a `Range` header, streamed to disk in chunks.
    ///
    /// A plain `URLSession.data(from:)` would hold 547 MB in memory before writing a
    /// byte of it, which is not a thing to do on a laptop that is also recording audio.
    nonisolated public static let httpFetch: Fetch = { url, offset, sink in
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse {
            guard (200...299).contains(http.statusCode) else {
                throw InstallerError.http(http.statusCode)
            }
        }

        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                sink(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
            try Task.checkCancellation()
        }
        if !buffer.isEmpty { sink(buffer) }
    }

    // MARK: - Helpers

    nonisolated static func size(of url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64 else { return 0 }
        return size
    }

    /// Hashed in 4 MB slices so a 547 MB file never lands in memory at once.
    nonisolated static func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Byte counter shared with the download callback, which runs off the main actor.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64
    private var lastReported: Int64

    init(_ start: Int64) {
        value = start
        lastReported = start
    }

    func add(_ delta: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        value += delta
        return value
    }

    func shouldReport() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value - lastReported >= 1 << 20 else { return false }
        lastReported = value
        return true
    }
}
