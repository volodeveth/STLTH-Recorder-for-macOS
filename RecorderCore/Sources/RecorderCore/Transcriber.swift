import Foundation
import OSLog

/// Turns a recorded session into `transcript.md`, locally (P5 bonus, ТЗ «наступний крок»).
///
/// Speaker attribution costs nothing here, and that is the point. Pipelines normally
/// have to guess who spoke — diarisation, with its own error rate. This one does not:
/// `mic.caf` is the advisor by construction and `system.caf` is the client, so the
/// tracks are transcribed separately and simply labelled.
///
/// Everything runs on the machine: the audio never leaves the advisor's Mac, which is
/// the same constraint that governs the recorder itself (F-3).
public enum Transcriber {

    private static let logger = Logger(subsystem: "ua.stlth.STLTHRecorder", category: "Transcriber")

    public enum TranscriberError: LocalizedError {
        case toolMissing
        case modelMissing
        case conversionFailed(String)
        case whisperFailed(String)
        case noTracks

        public var errorDescription: String? {
            switch self {
            case .modelMissing:
                // No longer a shell command: the app downloads these itself now. The
                // old text pointed at scripts/setup-transcription.sh, which does not
                // exist on a machine that installed the DMG.
                return """
                    Моделі розпізнавання ще не завантажені.
                    Меню → Останні записи → сесія → «Увімкнути транскрибацію…»
                    """
            case .toolMissing:
                // Only reachable on a broken bundle or a dev build without the tool.
                return "У застосунку бракує whisper-cli. Перевстановіть STLTH Recorder for macOS."
            case .conversionFailed(let details):
                return "Не вдалося підготувати аудіо: \(details)"
            case .whisperFailed(let details):
                return "Розпізнавання не вдалося: \(details)"
            case .noTracks:
                return "У теці сесії немає аудіофайлів"
            }
        }
    }

    /// Where the binary and the model are looked for.
    ///
    /// Deliberately not bundled: whisper.cpp and a model add hundreds of megabytes to
    /// a recorder whose core job needs none of it. Shipping this as an optional local
    /// dependency keeps the product small and keeps the bonus honest — the menu item
    /// says plainly what is missing instead of pretending the feature is unavailable.
    static var toolCandidates: [String] {
        var paths: [String] = []
        // The bundled copy comes first and is the one that ships: built from source by
        // `scripts/build-whisper.sh` with the compute backends linked in, so it depends
        // on nothing but macOS. A Homebrew build cannot be bundled at all — that script
        // documents why.
        if let macOS = Bundle.main.executableURL?.deletingLastPathComponent() {
            paths.append(macOS.appendingPathComponent("whisper-cli").path)
        }
        // Kept for the dev bench, where a freshly brewed build is easier to swap.
        paths += [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
        ]
        return paths
    }

    /// Best first: the model the installer fetches, then what earlier versions left.
    ///
    /// `large-v3-q5_0` is what 1.3.0 installs (see `ModelInstaller.requiredModels`
    /// for why the full model over turbo). Turbo stays a candidate so a machine that
    /// has not re-downloaded keeps working; medium is the dev-bench fallback.
    ///
    /// The numbers below were measured on a **human voice through a real Zoom call**
    /// — 145 words of financial talk read aloud (`Tools/wer-live.sh`), not the
    /// synthesised sample that flatters every model. Large-v3 has no row: it was never
    /// run on this bench, and a number nobody measured is worse than a blank.
    ///
    /// | модель | розмір | WER | без чисел | година, на канал |
    /// |---|---|---|---|---|
    /// | `large-v3-q5_0` | 1 031 МБ | не міряно | не міряно | не міряно |
    /// | `large-v3-turbo-q5_0` | 547 МБ | **21.4 %** | **14.4 %** | ~9 хв |
    /// | `medium-q5_0` | 519 МБ | 26.2 % | 19.2 % | ~17 хв |
    /// | `small-q5_1` | 184 МБ | 89.0 % | 92.0 % | ~5 хв |
    ///
    /// Turbo beat medium on both axes at once — more accurate *and* twice as fast for
    /// thirty megabytes more — which is why medium is last.
    ///
    /// Small is deliberately absent. At 89 % it does not transcribe Ukrainian so much
    /// as invent it — 79 fabricated words against 145 spoken — and a fallback that
    /// silently produces fiction is worse than telling the user which model to fetch.
    static var modelCandidates: [String] {
        let home = NSHomeDirectory()
        let names = ["ggml-large-v3-q5_0.bin", "ggml-large-v3-turbo-q5_0.bin", "ggml-medium-q5_0.bin"]
        return names.flatMap { name in
            [
                // Where scripts/setup-transcription.sh puts them.
                "\(home)/Library/Application Support/STLTHRecorder/Models/\(name)",
                // Machine-wide, so a second account on the same Mac does not need its
                // own half-gigabyte copy.
                "/Users/Shared/whisper-models/\(name)",
                "\(home)/dev/models/\(name)",
                "\(home)/.cache/whisper/\(name)",
                "/opt/homebrew/share/whisper-cpp/\(name)",
            ]
        }
    }

    /// Voice activity detection model — 864 KB, and the single most valuable file here.
    ///
    /// `--suppress-nst` was not enough: the tail of a recording came back as «Дякую за
    /// перегляд!» every thirty seconds. That is not a stray non-speech token but a
    /// plausible sentence the model *invents* out of silence, and no suppression flag
    /// stops it. VAD does, by never handing silence to the model at all.
    static var vadModelCandidates: [String] {
        let home = NSHomeDirectory()
        let name = "ggml-silero-v5.1.2.bin"
        return [
            "\(home)/Library/Application Support/STLTHRecorder/Models/\(name)",
            "/Users/Shared/whisper-models/\(name)",
            "\(home)/dev/models/\(name)",
            "\(home)/.cache/whisper/\(name)",
        ]
    }

    public static func vadModel() -> String? {
        vadModelCandidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    static let modelSearchHint = "~/dev/models/ggml-large-v3-q5_0.bin"

    public static func tool() -> String? {
        toolCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func model() -> String? {
        modelCandidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Whether the menu item can do anything at all.
    public static var isAvailable: Bool { tool() != nil && model() != nil }

    /// What one run produced — and whether it found anything worth keeping.
    ///
    /// `hadSpeech` exists for exactly one caller: the decision to delete the source
    /// tracks afterwards. A transcript with no lines means recognition found nothing,
    /// and that is the one moment the audio must stay — so the fact travels with the
    /// result instead of being re-derived by parsing the markdown back.
    public struct TranscriptResult: Equatable, Sendable {
        public let url: URL
        public let hadSpeech: Bool

        public init(url: URL, hadSpeech: Bool) {
            self.url = url
            self.hadSpeech = hadSpeech
        }
    }

    /// Transcribe both tracks of a session and write `transcript.md` beside them.
    @discardableResult
    public static func transcribe(sessionDir: URL, language: String = "uk") throws -> TranscriptResult {
        guard let tool = tool() else { throw TranscriberError.toolMissing }
        guard let model = model() else { throw TranscriberError.modelMissing }

        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stlth-transcribe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var sections: [(title: String, lines: [(Int, String)])] = []
        for (file, title) in [("mic.caf", "Радник"), ("system.caf", "Клієнт")] {
            let source = sessionDir.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }

            // whisper wants 16 kHz mono; our tracks are 48 kHz and the system one is stereo.
            let wav = work.appendingPathComponent("\(file).wav")
            try run("/usr/bin/afconvert",
                    ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", source.path, wav.path],
                    wrap: TranscriberError.conversionFailed)

            let output = work.appendingPathComponent(file)
            // `--suppress-nst` and a raised no-speech threshold, because a meeting is
            // mostly silence and whisper fills silence with invention. On a real call
            // the tail of the recording came back as "[Режисер Микола Носок]" repeated
            // twenty-two times — 75 fabricated words against 145 spoken ones, which
            // took the measured error rate from 26% to 74%. Filtering bracketed lines
            // afterwards hides it from the transcript but still wastes minutes of
            // compute; refusing to transcribe silence in the first place is the fix.
            // Measured on a real recording of a human voice, turbo model:
            //
            //   без VAD   WER 21.4 %   9 вставок   22.5 с
            //   з VAD     WER 16.6 %   1 вставка   12.0 с
            //
            // Better and twice as fast at once, because silence is never transcribed —
            // and a meeting is mostly silence.
            var arguments = ["-m", model, "-f", wav.path, "-l", language,
                             "--suppress-nst",
                             "-oj", "-of", output.path, "--no-prints"]
            if let vad = vadModel() {
                arguments += ["--vad", "--vad-model", vad]
            } else {
                // Without VAD the model fills silence with invention, so lean on the
                // blunter instrument and say so in the log.
                arguments += ["--no-speech-thold", "0.8"]
                logger.warning("VAD model not found — transcript may contain invented lines in silence")
            }
            try run(tool, arguments, wrap: TranscriberError.whisperFailed)

            sections.append((title, try segments(at: output.appendingPathExtension("json"))))
        }

        guard !sections.isEmpty else { throw TranscriberError.noTracks }

        let meta = try? SessionMeta.load(from: sessionDir.appendingPathComponent("meta.json"))
        let target = sessionDir.appendingPathComponent("transcript.md")
        try markdown(sections: sections, meta: meta, model: model)
            .write(to: target, atomically: true, encoding: .utf8)

        logger.info("Transcript written for session at \(sessionDir.lastPathComponent, privacy: .public)")
        return TranscriptResult(url: target, hadSpeech: hasSpeech(sections))
    }

    // MARK: - Internals

    /// One recognised line on either track is speech; `[BLANK_AUDIO]`-style markers
    /// were already dropped by `segments(at:)`, so nothing here has to second-guess them.
    static func hasSpeech(_ sections: [(title: String, lines: [(Int, String)])]) -> Bool {
        sections.contains { !$0.lines.isEmpty }
    }

    private static func run(_ launchPath: String,
                            _ arguments: [String],
                            wrap: (String) -> TranscriberError) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let details = String(data: errorData, encoding: .utf8)?
                .split(separator: "\n").last.map(String.init) ?? "код \(process.terminationStatus)"
            throw wrap(details)
        }
    }

    private static func segments(at url: URL) throws -> [(Int, String)] {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["transcription"] as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            guard let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !text.isEmpty,
                  // whisper marks non-speech as [BLANK_AUDIO], [Музика] and similar.
                  !text.hasPrefix("["),
                  let offsets = item["offsets"] as? [String: Any],
                  let from = offsets["from"] as? Int else { return nil }
            return (from, text)
        }
    }

    private static func stamp(_ milliseconds: Int) -> String {
        let total = milliseconds / 1000
        return String(format: "%02d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }

    private static func markdown(sections: [(title: String, lines: [(Int, String)])],
                                 meta: SessionMeta?,
                                 model: String) -> String {
        var out = ["# Транскрипт сесії", ""]
        if let meta {
            out += [
                "**Сесія:** \(meta.sessionId)",
                "**Початок:** \(SessionMeta.dateFormatter.string(from: meta.startedAt))",
                "**Тривалість:** \(stamp(meta.durationMs))",
            ]
        }
        out += [
            "**Модель:** whisper.cpp `\((model as NSString).lastPathComponent)` — локально,"
                + " аудіо не залишає цей Mac",
            "",
            "> Розділення за спікерами не вгадується: `mic.caf` — це завжди радник,",
            "> `system.caf` — завжди співрозмовник. Атрибуція реплік випливає з того,",
            "> як зроблено запис, а не з моделі діаризації.",
            "",
        ]
        for section in sections {
            out += ["## \(section.title)", ""]
            if section.lines.isEmpty {
                out.append("_(мовлення не розпізнано)_")
            } else {
                out += section.lines.map { "`[\(stamp($0.0))]` \($0.1)" }
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }
}
