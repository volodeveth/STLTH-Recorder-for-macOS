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

    // MARK: - What the user is told before agreeing

    @Test("The advertised download size matches what is actually fetched")
    func sizeMatchesModels() {
        let sum = ModelInstaller.requiredModels.reduce(Int64(0)) { $0 + $1.bytes }
        #expect(ModelInstaller.totalBytes == sum)
        #expect(sum == 574_926_293)

        // README, the design note and `ls -lh` all speak in MiB — 547 МБ for the speech
        // model, 548 for both. `ByteCountFormatter.file` is decimal and would tell the
        // user 574,9 МБ instead, so the UI must use the binary style or the number the
        // advisor agrees to stops matching the number the project documents.
        let shown = ByteCountFormatter.string(fromByteCount: sum, countStyle: .binary)
        #expect(shown.contains("548"))
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
