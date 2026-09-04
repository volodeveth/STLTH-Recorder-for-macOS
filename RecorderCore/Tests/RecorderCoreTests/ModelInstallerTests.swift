import CryptoKit
import Foundation
import Testing
@testable import RecorderCore

/// The installer exists so the advisor never opens a terminal, which means its failure
/// modes are the interesting part: a connection that drops halfway, a server that
/// answers with an error page instead of a model, a user who changes their mind. None
/// of these tests touch the network — the fetch is injected.
@Suite("ModelInstaller")
struct ModelInstallerTests {

    // MARK: - Fixtures

    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stlth-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A stand-in for one of the real models: same shape, three bytes instead of 547 MB.
    private func fakeModel(_ payload: Data, name: String = "fake-model.bin") -> ModelInstaller.Model {
        ModelInstaller.Model(
            name: name,
            url: URL(string: "https://example.invalid/\(name)")!,
            bytes: Int64(payload.count),
            sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
            purpose: "тест")
    }

    /// Serves `payload` from the requested offset, one chunk.
    private func fetch(_ payload: Data) -> ModelInstaller.Fetch {
        { _, offset, sink in
            sink(payload.suffix(from: Int(offset)))
        }
    }

    // MARK: - The happy path

    @Test("A model lands at its final name only after it verifies")
    func downloadsAndRenames() async throws {
        let dir = try makeDirectory()
        let payload = Data("це модель, майже півгігабайта".utf8)
        let model = fakeModel(payload)

        try await ModelInstaller.download(model, into: dir, fetch: fetch(payload),
                                          baseline: 0, progress: { _, _ in })

        let target = dir.appendingPathComponent(model.name)
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(try Data(contentsOf: target) == payload)
        // No debris left behind.
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathExtension("part").path))
    }

    // MARK: - Interruption

    @Test("A dropped connection resumes from the byte it stopped at, not from zero")
    func resumesFromPartialFile() async throws {
        let dir = try makeDirectory()
        let payload = Data((0..<5000).map { UInt8($0 % 251) })
        let model = fakeModel(payload)

        // Simulate an attempt that died after 2000 bytes.
        let part = dir.appendingPathComponent(model.name).appendingPathExtension("part")
        try payload.prefix(2000).write(to: part)

        var requestedOffset: Int64 = -1
        let counting: ModelInstaller.Fetch = { _, offset, sink in
            requestedOffset = offset
            sink(payload.suffix(from: Int(offset)))
        }

        try await ModelInstaller.download(model, into: dir, fetch: counting,
                                          baseline: 0, progress: { _, _ in })

        #expect(requestedOffset == 2000)
        #expect(try Data(contentsOf: dir.appendingPathComponent(model.name)) == payload)
    }

    @Test("A part file longer than the model is thrown away rather than resumed")
    func discardsOversizedPartial() async throws {
        let dir = try makeDirectory()
        let payload = Data("модель".utf8)
        let model = fakeModel(payload)

        let part = dir.appendingPathComponent(model.name).appendingPathExtension("part")
        try Data(repeating: 0xFF, count: payload.count + 100).write(to: part)

        var requestedOffset: Int64 = -1
        let counting: ModelInstaller.Fetch = { _, offset, sink in
            requestedOffset = offset
            sink(payload.suffix(from: Int(offset)))
        }

        try await ModelInstaller.download(model, into: dir, fetch: counting,
                                          baseline: 0, progress: { _, _ in })

        #expect(requestedOffset == 0)
        #expect(try Data(contentsOf: dir.appendingPathComponent(model.name)) == payload)
    }

    // MARK: - Corruption

    @Test("An error page served instead of a model is rejected, not saved")
    func rejectsWrongContent() async throws {
        let dir = try makeDirectory()
        let model = fakeModel(Data("справжня модель".utf8))
        let errorPage = Data("<html><body>404 Not Found</body></html>".utf8)

        await #expect(throws: ModelInstaller.InstallerError.self) {
            try await ModelInstaller.download(model, into: dir, fetch: self.fetch(errorPage),
                                              baseline: 0, progress: { _, _ in })
        }

        // Neither the final file nor a partial one survives a failed digest.
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(model.name).path))
    }

    @Test("A truncated download never becomes the final file")
    func rejectsTruncated() async throws {
        let dir = try makeDirectory()
        let payload = Data((0..<3000).map { UInt8($0 % 97) })
        let model = fakeModel(payload)

        let short: ModelInstaller.Fetch = { _, _, sink in sink(payload.prefix(1500)) }

        await #expect(throws: ModelInstaller.InstallerError.self) {
            try await ModelInstaller.download(model, into: dir, fetch: short,
                                              baseline: 0, progress: { _, _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(model.name).path))
    }

    // MARK: - Presence

    @Test("A half-finished file never counts as installed")
    func partialIsNotInstalled() throws {
        let dir = try makeDirectory()
        let model = ModelInstaller.requiredModels[0]

        // Same name, wrong size — exactly what a killed download leaves behind.
        try Data(repeating: 0, count: 1024).write(to: dir.appendingPathComponent(model.name))

        #expect(!ModelInstaller.isPresent(model, in: dir))
        #expect(!ModelInstaller.isInstalled(in: dir))
    }

    @Test("Both models are required, not just the big one")
    func vadIsNotOptional() throws {
        let dir = try makeDirectory()
        // Only the speech model, at its exact size.
        let speech = ModelInstaller.requiredModels[0]
        FileManager.default.createFile(atPath: dir.appendingPathComponent(speech.name).path,
                                       contents: nil)
        let handle = try FileHandle(forWritingTo: dir.appendingPathComponent(speech.name))
        try handle.truncate(atOffset: UInt64(speech.bytes))
        try handle.close()

        #expect(ModelInstaller.isPresent(speech, in: dir))
        #expect(!ModelInstaller.isInstalled(in: dir))
    }

    // MARK: - Removal

    @Test("Removing the models frees the partial downloads too")
    @MainActor
    func removalClearsEverything() async throws {
        let dir = try makeDirectory()
        let installer = ModelInstaller(directory: dir, fetch: { _, _, _ in })

        for model in ModelInstaller.requiredModels {
            try Data("x".utf8).write(to: dir.appendingPathComponent(model.name))
            try Data("y".utf8).write(to: dir.appendingPathComponent(model.name)
                .appendingPathExtension("part"))
        }

        try installer.removeModels()

        for model in ModelInstaller.requiredModels {
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(model.name).path))
            #expect(!FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(model.name).appendingPathExtension("part").path))
        }
        #expect(installer.state == .notInstalled)
    }

    @Test("Deleting the models takes a leftover turbo file with them")
    @MainActor
    func removalIncludesSuperseded() throws {
        let dir = try makeDirectory()
        let installer = ModelInstaller(directory: dir, fetch: { _, _, _ in })
        let turbo = dir.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
        try Data("x".utf8).write(to: turbo)
        try Data("y".utf8).write(to: turbo.appendingPathExtension("part"))

        try installer.removeModels()

        #expect(!FileManager.default.fileExists(atPath: turbo.path))
        #expect(!FileManager.default.fileExists(atPath: turbo.appendingPathExtension("part").path))
    }

    // MARK: - Replacing the model

    @Test("The turbo model is removed only after its replacement verified")
    func supersededGoesAfterSuccess() async throws {
        let dir = try makeDirectory()
        let turbo = dir.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
        try Data("стара модель".utf8).write(to: turbo)
        let payload = Data("нова модель".utf8)
        let model = fakeModel(payload)

        try await ModelInstaller.downloadAll(into: dir, models: [model],
                                             fetch: fetch(payload), progress: { _, _ in })

        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(model.name).path))
        #expect(!FileManager.default.fileExists(atPath: turbo.path))
    }

    @Test("A failed replacement leaves the turbo model in place")
    func supersededSurvivesFailure() async throws {
        // Otherwise a dropped download would leave the user with no working model at
        // all — the one outcome worse than a stale one.
        let dir = try makeDirectory()
        let turbo = dir.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
        try Data("стара модель".utf8).write(to: turbo)
        let model = fakeModel(Data("нова модель".utf8))
        let errorPage = Data("<html>502 Bad Gateway</html>".utf8)

        await #expect(throws: ModelInstaller.InstallerError.self) {
            try await ModelInstaller.downloadAll(into: dir, models: [model],
                                                 fetch: self.fetch(errorPage), progress: { _, _ in })
        }

        #expect(FileManager.default.fileExists(atPath: turbo.path))
        #expect(try Data(contentsOf: turbo) == Data("стара модель".utf8))
    }

    @Test("A cancelled replacement leaves the turbo model in place")
    func supersededSurvivesCancellation() async throws {
        let dir = try makeDirectory()
        let turbo = dir.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
        try Data("стара модель".utf8).write(to: turbo)
        let model = fakeModel(Data("нова модель".utf8))
        let cancelled: ModelInstaller.Fetch = { _, _, _ in throw CancellationError() }

        await #expect(throws: CancellationError.self) {
            try await ModelInstaller.downloadAll(into: dir, models: [model],
                                                 fetch: cancelled, progress: { _, _ in })
        }

        #expect(FileManager.default.fileExists(atPath: turbo.path))
    }

    @Test("The shipped list names large-v3 first and turbo as superseded")
    func shippedModelsAreLargeV3() {
        #expect(ModelInstaller.requiredModels[0].name == "ggml-large-v3-q5_0.bin")
        #expect(ModelInstaller.requiredModels[0].bytes == 1_081_140_203)
        #expect(ModelInstaller.requiredModels[0].sha256
                == "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1")
        #expect(ModelInstaller.supersededModels == ["ggml-large-v3-turbo-q5_0.bin"])
        // A superseded model must never also be required, or it would be deleted the
        // moment it finished downloading.
        for model in ModelInstaller.requiredModels {
            #expect(!ModelInstaller.supersededModels.contains(model.name))
        }
    }

    @Test("The old model still counts for Transcriber until it is replaced")
    func turboRemainsACandidate() {
        // A machine that has not re-downloaded keeps transcribing on turbo; the new
        // model simply wins when both are present.
        let dir = ModelInstaller.defaultDirectory
        let candidates = Transcriber.modelCandidates
        let new = candidates.firstIndex(of: dir.appendingPathComponent("ggml-large-v3-q5_0.bin").path)
        let old = candidates.firstIndex(of: dir.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin").path)
        #expect(new != nil)
        #expect(old != nil)
        if let new, let old { #expect(new < old) }
    }

    // MARK: - What the user is told before agreeing

    @Test("The advertised download size matches what is actually fetched")
    func sizeMatchesModels() {
        let sum = ModelInstaller.requiredModels.reduce(Int64(0)) { $0 + $1.bytes }
        #expect(ModelInstaller.totalBytes == sum)
        #expect(sum == 1_082_025_301)

        // README and `ls -lh` speak in binary units — 1 031 МБ for the speech model,
        // 1,01 ГБ for both. `ByteCountFormatter.file` is decimal and would say 1,08 ГБ,
        // so the UI must use the binary style or the number the advisor agrees to
        // stops matching the number the project documents. The decimal separator is
        // the runner's locale, hence both spellings.
        let shown = ByteCountFormatter.string(fromByteCount: sum, countStyle: .binary)
        #expect(shown.contains("1.01") || shown.contains("1,01"))
    }

    @Test("Models are looked for where Transcriber already searches")
    func directoryAgreesWithTranscriber() {
        let expected = ModelInstaller.defaultDirectory.appendingPathComponent(
            ModelInstaller.requiredModels[0].name).path
        #expect(Transcriber.modelCandidates.contains(expected))

        let vad = ModelInstaller.defaultDirectory.appendingPathComponent(
            ModelInstaller.requiredModels[1].name).path
        #expect(Transcriber.vadModelCandidates.contains(vad))
    }
}
