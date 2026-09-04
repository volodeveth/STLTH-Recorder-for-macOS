// The one test that runs whisper for real.
//
// Everything else in the suite stubs the model out, which proves the plumbing and
// nothing about the model file itself — whether whisper-cli v1.9.2 opens
// ggml-large-v3-q5_0.bin, whether its JSON has the shape `segments(at:)` parses,
// whether speech is actually detected and the audio-removal pipeline behaves on a
// real transcript. Compiled together with the core sources (see `make
// e2e-transcription`), so internal API is reachable without a test bundle, and run on
// the CI Mac runner by .github/workflows/e2e-transcription.yml. Any failed check
// exits non-zero.
//
// Environment:
//   E2E_VOICE     — `say` voice; empty means the system default
//   E2E_LANGUAGE  — whisper language code matching that voice (uk / en)

import AVFoundation
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ✅ \(message)")
    } else {
        print("  ❌ \(message)")
        exit(1)
    }
}

struct CommandFailed: Error, CustomStringConvertible {
    let description: String
}

func run(_ launchPath: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let stderr = Pipe()
    process.standardError = stderr
    try process.run()
    let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CommandFailed(description: "\(launchPath) \(arguments.joined(separator: " ")) → \(process.terminationStatus): \(errorText)")
    }
}

func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

let environment = ProcessInfo.processInfo.environment
let voice = environment["E2E_VOICE"] ?? ""
let language = environment["E2E_LANGUAGE"] ?? "uk"

let work = FileManager.default.temporaryDirectory
    .appendingPathComponent("stlth-e2e-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

// MARK: - 1. Real download into the directory Transcriber searches first

print("==> 1. Models, through the app's own installer")
let models = ModelInstaller.defaultDirectory
try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
let staleTurbo = models.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
try Data("stale".utf8).write(to: staleTurbo)

let downloadStarted = Date()
let reported = Reported()
try await ModelInstaller.downloadAll(into: models, fetch: ModelInstaller.httpFetch) { file, done in
    if await reported.crossed(done, every: 200 << 20) {
        print("    \(file): \(done >> 20) MB")
    }
}
print("    download took \(Int(Date().timeIntervalSince(downloadStarted))) s")

check(ModelInstaller.isInstalled(in: models), "both models present at their pinned size and digest")
check(!exists(staleTurbo), "superseded turbo removed after the replacement verified")
check(Transcriber.tool() != nil, "whisper-cli found next to this binary: \(Transcriber.tool() ?? "-")")
check(Transcriber.model()?.hasSuffix("ggml-large-v3-q5_0.bin") == true, "large-v3 is the model Transcriber picks")
check(Transcriber.vadModel() != nil, "VAD model found")

// MARK: - 2. A session with speech

print("==> 2. A spoken session, transcribed with large-v3, audio removal on")
let text = language == "uk"
    ? "Доброго дня. Сьогодні ми обговоримо структуру вашого портфеля та цілі на найближчі три роки."
    : "Good afternoon. Today we will discuss the structure of your portfolio and your goals for the next three years."

let aiff = work.appendingPathComponent("speech.aiff")
var sayArguments = ["-o", aiff.path, text]
if !voice.isEmpty { sayArguments = ["-v", voice] + sayArguments }
try run("/usr/bin/say", sayArguments)
print("    voice: \(voice.isEmpty ? "system default" : voice), language: \(language)")

let store = SessionStore(root: work.appendingPathComponent("Sessions", isDirectory: true))
try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)

/// A session directory the way the recorder leaves one: two 48 kHz LPCM tracks and a
/// completed meta.json. `source == nil` means ten seconds of digital silence.
func makeSession(from source: URL?) throws -> SessionHandle {
    let handle = try store.begin(consentAt: Date())
    let mic = handle.dir.appendingPathComponent("mic.caf")
    let system = handle.dir.appendingPathComponent("system.caf")
    if let source {
        try run("/usr/bin/afconvert", ["-f", "caff", "-d", "LEI16@48000", "-c", "1", source.path, mic.path])
        do {
            try run("/usr/bin/afconvert", ["-f", "caff", "-d", "LEI16@48000", "-c", "2", source.path, system.path])
        } catch {
            // afconvert on this macOS would not upmix; a mono client track still
            // exercises everything the pipeline does with it.
            try FileManager.default.copyItem(at: mic, to: system)
        }
    } else {
        try writeSilence(to: mic, channels: 1)
        try writeSilence(to: system, channels: 2)
    }
    // Stands in for the mixdown: it must survive audio removal untouched.
    try Data("stand-in".utf8).write(to: handle.dir.appendingPathComponent("session.m4a"))
    try store.complete(handle, result: RecordingResult(
        micURL: mic, systemURL: system, durationMs: 10_000,
        inputDeviceName: "e2e", outputDeviceName: "e2e"))
    return handle
}

func writeSilence(to url: URL, channels: AVAudioChannelCount) throws {
    // Scoped so the writer is released — and the CAF header finalised — before the
    // file is read back.
    let writer = try CAFWriter(url: url, channels: channels)
    try writer.writeSilence(frames: 10 * 48_000)
    _ = writer.framesWritten
}

func transcribe(_ dir: URL) throws -> Transcriber.TranscriptResult {
    try Transcriber.transcribe(sessionDir: dir, language: language)
}

let spoken = try makeSession(from: aiff)
let started = Date()
let result = try TranscriptionPipeline.run(sessionDir: spoken.dir, store: store,
                                           deleteAudio: { true }, transcribe: transcribe)
print("    whisper took \(Int(Date().timeIntervalSince(started))) s for two tracks")
let transcript = try String(contentsOf: result.url, encoding: .utf8)
print(transcript.split(separator: "\n").map { "    | \($0)" }.joined(separator: "\n"))

check(result.hadSpeech, "speech detected")
check(transcript.contains("`[00:00:"), "transcript has at least one timestamped line")
check(!exists(spoken.dir.appendingPathComponent("mic.caf")), "mic.caf removed")
check(!exists(spoken.dir.appendingPathComponent("system.caf")), "system.caf removed")
check(exists(spoken.dir.appendingPathComponent("session.m4a")), "session.m4a kept")
check(exists(result.url), "transcript.md kept")
let spokenMeta = try SessionMeta.load(from: spoken.dir.appendingPathComponent("meta.json"))
check(spokenMeta.audioRemovedAt != nil, "audioRemovedAt recorded in meta.json")
check(spokenMeta.status == .completed, "session still reads as completed")

// MARK: - 3. A silent session keeps its audio

print("==> 3. A silent session, audio removal on")
let silent = try makeSession(from: nil)
let quiet = try TranscriptionPipeline.run(sessionDir: silent.dir, store: store,
                                          deleteAudio: { true }, transcribe: transcribe)
check(!quiet.hadSpeech, "no speech in silence")
check(exists(silent.dir.appendingPathComponent("mic.caf")), "silent session keeps mic.caf")
check(exists(silent.dir.appendingPathComponent("system.caf")), "silent session keeps system.caf")
check(try SessionMeta.load(from: silent.dir.appendingPathComponent("meta.json")).audioRemovedAt == nil,
      "silent session not marked as stripped")

// MARK: - 4. Two sessions through the queue never overlap

print("==> 4. Two sessions through SerialTaskQueue")
let a = try makeSession(from: aiff)
let b = try makeSession(from: aiff)
let queue = SerialTaskQueue()
let stamps = Stamps()
// Top-level constants in main.swift are main-actor isolated; the jobs run elsewhere,
// so they take copies through capture lists rather than reaching back for them.
let first = await queue.enqueue { [store, stamps, dir = a.dir, language] in
    await stamps.add("A start")
    _ = try TranscriptionPipeline.run(sessionDir: dir, store: store, deleteAudio: { false },
                                      transcribe: { try Transcriber.transcribe(sessionDir: $0, language: language) })
    await stamps.add("A end")
}
let second = await queue.enqueue { [store, stamps, dir = b.dir, language] in
    await stamps.add("B start")
    _ = try TranscriptionPipeline.run(sessionDir: dir, store: store, deleteAudio: { false },
                                      transcribe: { try Transcriber.transcribe(sessionDir: $0, language: language) })
    await stamps.add("B end")
}
try await first.value
try await second.value
let order = await stamps.order
check(order == ["A start", "A end", "B start", "B end"], "B started only after A finished: \(order)")
check(exists(a.dir.appendingPathComponent("mic.caf")) && exists(b.dir.appendingPathComponent("mic.caf")),
      "audio kept when the option is off")

try? FileManager.default.removeItem(at: work)
print("✅ end-to-end transcription passed")

// MARK: - Helpers declared after use; type declarations are hoisted in main.swift

actor Reported {
    private var last: Int64 = 0
    func crossed(_ value: Int64, every step: Int64) -> Bool {
        guard value - last >= step else { return false }
        last = value
        return true
    }
}

actor Stamps {
    private(set) var order: [String] = []
    func add(_ event: String) { order.append(event) }
}
