# Автотранскрибація, видалення аудіо, large-v3 — план реалізації

> Кроки позначені чекбоксами (`- [ ]`) — план виконується задача за задачею.
> Кожна задача завершується пушем і зеленим CI: локальної збірки немає.

**Goal:** Перенести з Windows-версії (v1.3.0) три поведінки: автоматичну транскрибацію
після кожного запису з чергою по одній сесії; необов'язкове видалення вихідних доріжок
після транскрибації; перехід на модель `ggml-large-v3-q5_0` з прибиранням застарілої turbo.

**Architecture:** Уся логіка, яку можна перевірити без UI, живе в `RecorderCore`
(headless SPM-пакет, тестується на CI): результат транскрибації з ознакою «була мова»,
чиста функція рішення про видалення, `SessionStore.removeAudio`, серійна черга
(`actor`), спільний конвеєр «транскрибувати → можливо видалити» і прибирання застарілої
моделі. У `App/Sources` — лише тонкий `TranscriptionService` за кресленням
`MixdownService`, тумблери в налаштуваннях і стани меню.

**Tech Stack:** Swift 5.10, swift-testing, SwiftUI `MenuBarExtra`, whisper.cpp
(`whisper-cli`), GitHub Actions `macos-15`.

**Референс:** `C:\myapps\STLTH Recorder` — `src/Stlth.App/TranscriptionService.cs`,
`src/Stlth.Core/Storage/SessionStore.cs:184-224`,
`src/Stlth.Core/Transcription/ModelInstaller.cs`, `tests/Stlth.Core.Tests/AudioRemovalTests.cs`.

## Global Constraints

- **Локальної збірки немає.** `swift`, `make`, `xcodebuild` на Windows не запускати. Цикл:
  правки → коміт → `git push` → `gh run watch <id> --exit-status` → читати лог.
- На CI компілюється **лише `RecorderCore`**. SwiftUI-шар (`App/Sources`) не
  компілюється взагалі — писати консервативно, за наявними зразками.
- UI-рядки — українською. Локалізацію не додавати.
- Коментарі — англійською, пояснюють «чому», з числами й посиланнями на артефакти.
- Тести: `import Testing`, `@Suite("…")`, `@Test`, тимчасові теки
  `FileManager.default.temporaryDirectory.appendingPathComponent("stlth-<що>-\(UUID())")`.
- Коміти: Conventional Commits, англійською.
- Не чіпати сторонні URL (`insidegui/AudioCap`, `ggerganov/whisper.cpp`,
  `ggml-org/whisper-vad`, `ggml-org/whisper.cpp`).
- Не перейменовувати теки сесій; не додавати вибір мови інтерфейсу.
- Версія: `project.yml` (`CFBundleShortVersionString`, `MARKETING_VERSION` 1.2.0 → 1.3.0;
  `CFBundleVersion`, `CURRENT_PROJECT_VERSION` 3 → 4) і `App/Info.plist:20,22`.
- Реліз не публікувати без окремої команди.

## Карта файлів

| Файл | Що змінюється |
|---|---|
| `RecorderCore/Sources/RecorderCore/Transcriber.swift` | `TranscriptResult`, `hasSpeech(_:)`, нові `modelCandidates`, `modelSearchHint`, таблиця в doc-коментарі |
| `RecorderCore/Sources/RecorderCore/SessionMeta.swift` | `audioRemovedAt: Date?` |
| `RecorderCore/Sources/RecorderCore/SessionStore.swift` | `mayRemoveAudio(enabled:hadSpeech:)`, `removeAudio(at:)` |
| `RecorderCore/Sources/RecorderCore/SerialTaskQueue.swift` | **новий** — `actor`, по одній роботі за раз |
| `RecorderCore/Sources/RecorderCore/TranscriptionPipeline.swift` | **новий** — спільна точка для авто й ручного шляху |
| `RecorderCore/Sources/RecorderCore/ModelInstaller.swift` | large-v3, `supersededModels`, `removeSuperseded(in:)`, параметризований `downloadAll` |
| `RecorderCore/Tests/RecorderCoreTests/TranscriberTests.swift` | **новий** |
| `RecorderCore/Tests/RecorderCoreTests/AudioRemovalTests.swift` | **новий** |
| `RecorderCore/Tests/RecorderCoreTests/SerialTaskQueueTests.swift` | **новий** |
| `RecorderCore/Tests/RecorderCoreTests/TranscriptionPipelineTests.swift` | **новий** |
| `RecorderCore/Tests/RecorderCoreTests/ModelInstallerTests.swift` | нові тести на superseded, оновлені суми |
| `App/Sources/TranscriptionService.swift` | **новий** — за кресленням `MixdownService` |
| `App/Sources/RecentSessionsMenu.swift` | стани меню через сервіс; поведінка без доріжок |
| `App/Sources/MenuBarView.swift` | точка авто-запуску після `mixAfterRecording` |
| `App/Sources/STLTHRecorderApp.swift` | `@StateObject` сервісу, прокидання |
| `App/Sources/SettingsView.swift` | два тумблери, попередження, підказка про стару модель |
| `App/Sources/TranscriptionSetupWindow.swift` | коментар із розміром |
| `scripts/setup-transcription.sh` | нова модель, прибирання turbo |
| `README.md`, `docs/ENGINEERING_NOTES.md`, `docs/design/specs/2026-08-10-transcription-setup.md` | документація |
| `project.yml`, `App/Info.plist` | версія |

## Порядок комітів

| # | Коміт | CI перевіряє |
|---|---|---|
| 0 | `ci: build the app bundle on every push` | `scripts/build-app.sh release` компілює і лінкує `App/Sources` — відтепер SwiftUI-шар не сліпа зона |
| 1 | `feat(core): report whether a transcript found any speech` | `TranscriberTests` + збірка застосунку |
| 2 | `feat(core): audio removal after transcription` | `AudioRemovalTests` (9 тестів) |
| 3 | `feat(core): serial queue and shared transcription pipeline` | `SerialTaskQueueTests`, `TranscriptionPipelineTests` |
| 4 | `feat(app): transcribe automatically after every recording` | збірка застосунку (job з кроку 0) |
| 5 | `feat(core): switch to large-v3 and retire the turbo model` | `ModelInstallerTests` |
| 6 | `ci: end-to-end transcription on the runner` | `workflow_dispatch`: справжній whisper-cli + справжня large-v3 на macOS-ранері, конвеєр із видаленням аудіо |
| 7 | `docs: describe auto-transcription, audio removal and large-v3` | — (після рішення щодо WER-числа) |
| 8 | `chore: bump version to 1.3.0 (build 4)` | — |

Після кожного пушу: `gh run list --limit 1` → `gh run watch <id> --exit-status`.

**Чому кроки 0 і 6 — не опція.** Користувач не має Mac узагалі. Без кроку 0 помилка
компіляції в `App/Sources` доїхала б до DMG непоміченою; без кроку 6 ніхто б не
перевірив, що новий файл моделі взагалі відкривається зібраним whisper-cli v1.9.2 і що
конвеєр «транскрибувати → видалити аудіо» працює на живому macOS, а не лише зі стабом.

---

### Task 0: CI збирає застосунок на кожен push

**Files:**
- Modify: `.github/workflows/ci.yml`

`scripts/build-app.sh release` уже вміє зібрати `.app` без Xcode: `swift build` ядра,
`swiftc` для `App/Sources/*.swift`, вкладання whisper-cli (cmake, ~5 хв — кешується за
версією з `scripts/build-whisper.sh`), ad-hoc підпис. Саме це робить `release.yml`,
тож на push виконується той самий шлях, лише без DMG.

- [ ] **Step 1: Нова джоба**

```yaml
  app-build:
    name: App bundle (SwiftUI layer compiles and links)
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Show toolchain
        run: swift --version && xcodebuild -version
      # whisper-cli takes minutes to build and changes only when its pinned version
      # does, so the built binary is cached on that version.
      - name: Cache whisper-cli
        uses: actions/cache@v4
        with:
          path: build/whisper
          key: whisper-cli-${{ runner.os }}-${{ hashFiles('scripts/build-whisper.sh') }}
      # The core's own job runs `swift test`; this one is here because App/Sources is
      # compiled by nothing else on a push. Without it a SwiftUI error ships in the DMG.
      - name: Build STLTHRecorder.app (no Xcode, same path as release.sh)
        run: scripts/build-app.sh release
      - name: The bundle carries whisper-cli
        run: test -x build/STLTHRecorder.app/Contents/MacOS/whisper-cli
```

- [ ] **Step 2: Коміт, пуш, CI — має бути зелено ще до будь-яких змін коду**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: build the app bundle on every push"
git push && gh run watch $(gh run list --limit 1 --json databaseId -q '.[0].databaseId') --exit-status
```

---

### Task 1: `Transcriber` повідомляє, чи знайшлася мова

**Files:**
- Modify: `RecorderCore/Sources/RecorderCore/Transcriber.swift:139-190`
- Modify: `App/Sources/RecentSessionsMenu.swift:93`
- Create: `RecorderCore/Tests/RecorderCoreTests/TranscriberTests.swift`

**Interfaces:**
- Produces: `Transcriber.TranscriptResult { url: URL; hadSpeech: Bool }`;
  `Transcriber.transcribe(sessionDir:language:) throws -> TranscriptResult`;
  internal `Transcriber.hasSpeech(_ sections:) -> Bool`.

- [ ] **Step 1: Падаючий тест**

```swift
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
}
```

- [ ] **Step 2: Реалізація**

У `Transcriber` перед `transcribe`:

```swift
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
```

Сигнатура: `public static func transcribe(sessionDir: URL, language: String = "uk") throws -> TranscriptResult`;
у кінці `return TranscriptResult(url: target, hadSpeech: hasSpeech(sections))`.

В `// MARK: - Internals`:

```swift
    static func hasSpeech(_ sections: [(title: String, lines: [(Int, String)])]) -> Bool {
        sections.contains { !$0.lines.isEmpty }
    }
```

`RecentSessionsMenu.swift:93`: `let transcript = try Transcriber.transcribe(sessionDir: directory).url`.

- [ ] **Step 3: Коміт, пуш, CI**

```bash
git add RecorderCore App/Sources/RecentSessionsMenu.swift
git commit -m "feat(core): report whether a transcript found any speech"
git push && gh run watch $(gh run list --limit 1 --json databaseId -q '.[0].databaseId') --exit-status
```

---

### Task 2: Видалення аудіо в ядрі

**Files:**
- Modify: `RecorderCore/Sources/RecorderCore/SessionMeta.swift` (поле + `init`)
- Modify: `RecorderCore/Sources/RecorderCore/SessionStore.swift` (після `noteMix`)
- Create: `RecorderCore/Tests/RecorderCoreTests/AudioRemovalTests.swift`

**Interfaces:**
- Produces: `SessionMeta.audioRemovedAt: Date?`;
  `SessionStore.mayRemoveAudio(enabled: Bool, hadSpeech: Bool) -> Bool` (static);
  `SessionStore.removeAudio(at sessionDir: URL) -> Int64` (`@discardableResult`).

- [ ] **Step 1: Падаючі тести**

```swift
import Foundation
import Testing
@testable import RecorderCore

/// The only place in the product that deletes the user's recordings. So the rule is
/// checked from both sides: that it fires, and — above all — when it must not.
@Suite("Audio removal")
struct AudioRemovalTests {

    private func makeStore() throws -> SessionStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stlth-audio-removal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return SessionStore(root: root)
    }

    /// A session with two tracks. Their contents do not matter here — removal never
    /// opens them — so a few kilobytes stand in for an hour of audio.
    private func sessionWithAudio(in store: SessionStore) throws -> SessionHandle {
        let handle = try store.begin(consentAt: Date())
        try Data(repeating: 0x11, count: 4096).write(to: handle.dir.appendingPathComponent("mic.caf"))
        try Data(repeating: 0x22, count: 8192).write(to: handle.dir.appendingPathComponent("system.caf"))
        return handle
    }

    private func meta(of handle: SessionHandle) throws -> SessionMeta {
        try SessionMeta.load(from: handle.dir.appendingPathComponent("meta.json"))
    }

    // MARK: - The decision

    @Test("Nothing is deleted while the option is off")
    func offMeansNever() {
        #expect(!SessionStore.mayRemoveAudio(enabled: false, hadSpeech: true))
    }

    @Test("Nothing is deleted when the transcript found no speech")
    func silenceKeepsAudio() {
        // The worst possible outcome: the recording is gone and what remains is a file
        // saying «мовлення не розпізнано». An empty transcript is a reason to keep the
        // audio, not to get rid of it.
        #expect(!SessionStore.mayRemoveAudio(enabled: true, hadSpeech: false))
    }

    @Test("Deletion needs both the option and actual speech")
    func bothConditions() {
        #expect(SessionStore.mayRemoveAudio(enabled: true, hadSpeech: true))
    }

    // MARK: - The removal

    @Test("Removing audio frees the tracks and keeps everything derived")
    func keepsDerivedFiles() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let handle = try sessionWithAudio(in: store)
        try Data("# текст".utf8).write(to: handle.dir.appendingPathComponent("transcript.md"))
        try Data("звук".utf8).write(to: handle.dir.appendingPathComponent("session.m4a"))

        let freed = store.removeAudio(at: handle.dir)

        #expect(freed == 4096 + 8192)
        #expect(!FileManager.default.fileExists(atPath: handle.dir.appendingPathComponent("mic.caf").path))
        #expect(!FileManager.default.fileExists(atPath: handle.dir.appendingPathComponent("system.caf").path))
        #expect(FileManager.default.fileExists(atPath: handle.dir.appendingPathComponent("transcript.md").path))
        #expect(FileManager.default.fileExists(atPath: handle.dir.appendingPathComponent("session.m4a").path))
        #expect(FileManager.default.fileExists(atPath: handle.dir.appendingPathComponent("meta.json").path))
    }

    @Test("The removal is written into meta.json")
    func removalIsRecorded() throws {
        // The difference between "the files were removed on purpose" and "the files
        // vanished" has to be on record, not reconstructed by guesswork in six months.
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let handle = try sessionWithAudio(in: store)

        let before = Date()
        store.removeAudio(at: handle.dir)

        let removedAt = try #require(try meta(of: handle).audioRemovedAt)
        #expect(abs(removedAt.timeIntervalSince(before)) < 5)
    }

    @Test("A session without audio still lists")
    func stillLists() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let handle = try sessionWithAudio(in: store)
        store.removeAudio(at: handle.dir)

        let listed = store.list()

        #expect(listed.count == 1)
        #expect(listed.first?.sessionId == handle.id)
    }

    @Test("Removing twice frees nothing the second time")
    func idempotent() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let handle = try sessionWithAudio(in: store)

        #expect(store.removeAudio(at: handle.dir) > 0)
        #expect(store.removeAudio(at: handle.dir) == 0)
    }

    @Test("A session that never had audio is not marked as stripped")
    func emptyDirectoryIsNotStripped() throws {
        // An empty directory is not "the audio was deleted", and saying so would be a lie.
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let handle = try store.begin(consentAt: Date())

        store.removeAudio(at: handle.dir)

        #expect(try meta(of: handle).audioRemovedAt == nil)
    }

    // MARK: - meta.json compatibility

    @Test("audioRemovedAt survives a write/load round trip")
    func roundTrip() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let handle = try store.begin(consentAt: Date())
        let url = handle.dir.appendingPathComponent("meta.json")

        var meta = try SessionMeta.load(from: url)
        let stamp = Date(timeIntervalSince1970: 1_800_000_000.5)
        meta.audioRemovedAt = stamp
        try meta.write(to: url)

        let reloaded = try SessionMeta.load(from: url)
        #expect(reloaded.audioRemovedAt != nil)
        #expect(abs(reloaded.audioRemovedAt!.timeIntervalSince(stamp)) < 0.001)
    }

    @Test("A meta.json written before the field existed still decodes")
    func oldMetaDecodes() throws {
        // Recordings made before this option existed are read without any change.
        let json = """
        {
          "appVersion" : "1.2.0",
          "consent" : { "at" : "2026-08-12T14:00:03.412+03:00", "confirmed" : true },
          "deviceChanges" : [],
          "devices" : { "input" : "MacBook Pro Microphone", "output" : "MacBook Pro Speakers" },
          "durationMs" : 1500,
          "osVersion" : "15.0.0",
          "sessionId" : "B7F0E7A4-5F0B-4B2E-9F3B-7C1B2D3E4F50",
          "startedAt" : "2026-08-12T14:00:03.500+03:00",
          "status" : "completed",
          "tracks" : []
        }
        """
        let meta = try SessionMeta.decoder.decode(SessionMeta.self, from: Data(json.utf8))
        #expect(meta.audioRemovedAt == nil)
        #expect(meta.mixFile == nil)
    }
}
```

- [ ] **Step 2: Реалізація**

`SessionMeta.swift` — після `mixFile`:

```swift
    /// When the source tracks were deleted after transcription, if they were.
    ///
    /// Optional for the same reason as `mixFile`: sessions recorded before the option
    /// existed decode without it. Set only when something was actually freed, so a
    /// session without audio is never mistaken for a damaged one — the difference
    /// between "removed on purpose" and "vanished" is exactly what this records.
    public var audioRemovedAt: Date?
```

В `init` — параметр `audioRemovedAt: Date? = nil` останнім і присвоєння.

`SessionStore.swift` — після `noteMix`:

```swift
    /// Whether the source tracks may be deleted after a transcription run.
    ///
    /// A pure function, because this is the one decision in the product that destroys
    /// the user's data, and it has to be tested rather than guessed at along the way.
    ///
    /// The second condition is not a formality. A transcript with no lines means either
    /// recognition failed or nobody spoke — and deleting the audio at that moment is
    /// the worst possible outcome: the recording is gone, and what remains is a file
    /// that says «мовлення не розпізнано».
    public static func mayRemoveAudio(enabled: Bool, hadSpeech: Bool) -> Bool {
        enabled && hadSpeech
    }

    /// Delete the source tracks, keeping everything derived: the mixdown, the
    /// transcript and `meta.json`.
    ///
    /// Best effort, like `noteMix`: a track that cannot be removed simply stays for the
    /// next attempt, and the fact of removal is recorded only when something was
    /// actually freed — an empty directory is not "audio was deleted".
    /// - Returns: bytes freed.
    @discardableResult
    public func removeAudio(at sessionDir: URL) -> Int64 {
        var freed: Int64 = 0
        for name in ["mic.caf", "system.caf"] {
            let url = sessionDir.appendingPathComponent(name)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? Int64,
                  (try? fileManager.removeItem(at: url)) != nil else { continue }
            freed += size
        }
        if freed > 0 {
            let metaURL = sessionDir.appendingPathComponent("meta.json")
            if var meta = try? SessionMeta.load(from: metaURL) {
                meta.audioRemovedAt = Date()
                try? meta.write(to: metaURL)
            }
        }
        return freed
    }
```

- [ ] **Step 3: Коміт, пуш, CI**

```bash
git add RecorderCore
git commit -m "feat(core): audio removal after transcription"
git push && gh run watch $(gh run list --limit 1 --json databaseId -q '.[0].databaseId') --exit-status
```

---

### Task 3: Серійна черга і спільний конвеєр

**Files:**
- Create: `RecorderCore/Sources/RecorderCore/SerialTaskQueue.swift`
- Create: `RecorderCore/Sources/RecorderCore/TranscriptionPipeline.swift`
- Create: `RecorderCore/Tests/RecorderCoreTests/SerialTaskQueueTests.swift`
- Create: `RecorderCore/Tests/RecorderCoreTests/TranscriptionPipelineTests.swift`

**Interfaces:**
- Consumes: `Transcriber.TranscriptResult` (Task 1), `SessionStore.mayRemoveAudio`,
  `SessionStore.removeAudio(at:)` (Task 2).
- Produces: `public actor SerialTaskQueue { func enqueue<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) -> Task<T, Error> }`;
  `TranscriptionPipeline.run(sessionDir:store:deleteAudio:transcribe:) throws -> Transcriber.TranscriptResult`,
  де `deleteAudio: @Sendable () -> Bool` обчислюється **після** транскрибації.

- [ ] **Step 1: Падаючі тести черги**

```swift
import Foundation
import Testing
@testable import RecorderCore

@Suite("SerialTaskQueue")
struct SerialTaskQueueTests {

    /// Records what happened, in order, from any task.
    private actor Log {
        private(set) var events: [String] = []
        func add(_ event: String) { events.append(event) }
    }

    /// Holds a job until the test lets it go.
    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    private struct Failure: Error {}

    @Test("The second job does not start until the first has finished")
    func jobsNeverOverlap() async throws {
        let queue = SerialTaskQueue()
        let log = Log()
        let gate = Gate()

        let first = await queue.enqueue {
            await log.add("A start")
            await gate.wait()
            await log.add("A end")
        }
        let second = await queue.enqueue {
            await log.add("B start")
            await log.add("B end")
        }

        // Give B every chance to start early. It must not.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await log.events == ["A start"])

        await gate.open()
        try await first.value
        try await second.value
        #expect(await log.events == ["A start", "A end", "B start", "B end"])
    }

    @Test("A failing job does not block the ones behind it")
    func failureReleasesQueue() async throws {
        let queue = SerialTaskQueue()
        let failing = await queue.enqueue { throw Failure() }
        let next = await queue.enqueue { 42 }

        await #expect(throws: Failure.self) { try await failing.value }
        #expect(try await next.value == 42)
    }

    @Test("Jobs run in the order they were enqueued")
    func preservesOrder() async throws {
        let queue = SerialTaskQueue()
        let log = Log()
        var tasks: [Task<Void, Error>] = []
        for index in 0..<20 {
            tasks.append(await queue.enqueue { await log.add("\(index)") })
        }
        for task in tasks { try await task.value }
        #expect(await log.events == (0..<20).map(String.init))
    }
}
```

- [ ] **Step 2: Реалізація черги**

```swift
import Foundation

/// Runs jobs one after another, never two at once.
///
/// Transcription loads the CPU for roughly as long as the conversation lasted, per
/// track. Two sessions stopped in a row would start two whisper processes side by
/// side, each at half speed, on the machine of someone who has just hung up. So: a
/// queue. Not a semaphore — Swift concurrency has no blocking primitive that is safe
/// to hold across an `await` — but a chain of tasks, each waiting for the previous
/// one to finish before it starts. A job that throws releases the chain like any
/// other; only its own caller sees the error.
public actor SerialTaskQueue {

    private var tail: Task<Void, Never>?

    public init() {}

    /// Enqueue `work`. It starts after everything enqueued before it has finished —
    /// whether that finished by returning or by throwing.
    @discardableResult
    public func enqueue<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) -> Task<T, Error> {
        let previous = tail
        // Detached, so a job that blocks a thread (whisper does, for minutes) never
        // holds this actor and never lands on the caller's executor.
        let task = Task.detached(priority: .utility) {
            await previous?.value
            return try await work()
        }
        tail = Task { _ = try? await task.value }
        return task
    }
}
```

- [ ] **Step 3: Падаючі тести конвеєра**

```swift
import Foundation
import Testing
@testable import RecorderCore

/// The pipeline is the single place where "transcribe" and "maybe delete the audio"
/// meet, so its ordering is checked here with whisper replaced by a stub that writes
/// a transcript and reports whether it "heard" anything.
@Suite("TranscriptionPipeline")
struct TranscriptionPipelineTests {

    private struct Broken: Error {}

    private func makeSession() throws -> (SessionStore, SessionHandle) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stlth-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SessionStore(root: root)
        let handle = try store.begin(consentAt: Date())
        try Data(repeating: 1, count: 1024).write(to: handle.dir.appendingPathComponent("mic.caf"))
        try Data(repeating: 2, count: 1024).write(to: handle.dir.appendingPathComponent("system.caf"))
        return (store, handle)
    }

    private func stub(hadSpeech: Bool) -> TranscriptionPipeline.Transcribe {
        { dir in
            let url = dir.appendingPathComponent("transcript.md")
            try Data("# Транскрипт".utf8).write(to: url)
            return Transcriber.TranscriptResult(url: url, hadSpeech: hadSpeech)
        }
    }

    private func hasAudio(_ handle: SessionHandle) -> Bool {
        FileManager.default.fileExists(atPath: handle.dir.appendingPathComponent("mic.caf").path)
    }

    @Test("With the option on and speech found, the tracks go and the transcript stays")
    func removesWhenAllowed() throws {
        let (store, handle) = try makeSession()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let result = try TranscriptionPipeline.run(sessionDir: handle.dir, store: store,
                                                   deleteAudio: { true },
                                                   transcribe: stub(hadSpeech: true))

        #expect(result.hadSpeech)
        #expect(!hasAudio(handle))
        #expect(FileManager.default.fileExists(atPath: result.url.path))
        #expect(try SessionMeta.load(from: handle.dir.appendingPathComponent("meta.json")).audioRemovedAt != nil)
    }

    @Test("A transcript with no speech keeps the audio even with the option on")
    func keepsAudioOnSilence() throws {
        let (store, handle) = try makeSession()
        defer { try? FileManager.default.removeItem(at: store.root) }

        try TranscriptionPipeline.run(sessionDir: handle.dir, store: store,
                                      deleteAudio: { true },
                                      transcribe: stub(hadSpeech: false))

        #expect(hasAudio(handle))
    }

    @Test("With the option off nothing is deleted")
    func keepsAudioWhenOff() throws {
        let (store, handle) = try makeSession()
        defer { try? FileManager.default.removeItem(at: store.root) }

        try TranscriptionPipeline.run(sessionDir: handle.dir, store: store,
                                      deleteAudio: { false },
                                      transcribe: stub(hadSpeech: true))

        #expect(hasAudio(handle))
    }

    @Test("A failed transcription propagates and touches no audio")
    func failureKeepsAudio() throws {
        let (store, handle) = try makeSession()
        defer { try? FileManager.default.removeItem(at: store.root) }

        #expect(throws: Broken.self) {
            try TranscriptionPipeline.run(sessionDir: handle.dir, store: store,
                                          deleteAudio: { true },
                                          transcribe: { _ in throw Broken() })
        }
        #expect(hasAudio(handle))
    }

    @Test("The deletion decision is read after transcription, not before")
    func decisionIsReadLate() throws {
        // The setting can change while a long job is running; the value that counts is
        // the one at the moment of deletion, which is what the Windows build does too.
        let (store, handle) = try makeSession()
        defer { try? FileManager.default.removeItem(at: store.root) }
        var transcribed = false

        try TranscriptionPipeline.run(sessionDir: handle.dir, store: store,
                                      deleteAudio: { transcribed },
                                      transcribe: { dir in
                                          transcribed = true
                                          return try self.stub(hadSpeech: true)(dir)
                                      })

        #expect(!hasAudio(handle))
    }
}
```

- [ ] **Step 4: Реалізація конвеєра**

```swift
import Foundation

/// One entry point for both ways a transcription can start — automatically after a
/// recording, or by hand from the session menu.
///
/// The Windows build calls this `RunAsync`, and the reason is the same: if the two
/// paths diverged, the same enabled option — deleting the audio, above all — would
/// behave differently depending on how the person started recognition, and there
/// would be nothing to explain that with.
public enum TranscriptionPipeline {

    public typealias Transcribe = (URL) throws -> Transcriber.TranscriptResult

    /// Transcribe the session and, if allowed, drop the source tracks.
    ///
    /// - Parameter deleteAudio: asked *after* the transcript is on disk. Whisper runs
    ///   for minutes, and a setting the user flips meanwhile should count.
    /// - Returns: the transcription result; a failed removal never changes it.
    @discardableResult
    public static func run(sessionDir: URL,
                           store: SessionStore,
                           deleteAudio: () -> Bool,
                           transcribe: Transcribe = { try Transcriber.transcribe(sessionDir: $0) }
    ) throws -> Transcriber.TranscriptResult {
        let result = try transcribe(sessionDir)
        // Deletion last, and only on the tested condition: the transcript is already
        // written, so nothing that goes wrong here can take it away.
        if SessionStore.mayRemoveAudio(enabled: deleteAudio(), hadSpeech: result.hadSpeech) {
            store.removeAudio(at: sessionDir)
        }
        return result
    }
}
```

- [ ] **Step 5: Коміт, пуш, CI**

```bash
git add RecorderCore
git commit -m "feat(core): serial queue and shared transcription pipeline"
git push && gh run watch $(gh run list --limit 1 --json databaseId -q '.[0].databaseId') --exit-status
```

---

### Task 4: `TranscriptionService` і UI (не компілюється на CI — писати консервативно)

**Files:**
- Create: `App/Sources/TranscriptionService.swift`
- Modify: `App/Sources/RecentSessionsMenu.swift` (прибрати `transcribing`, `transcriptionError`, `transcribe`, `hasTranscript`; стани через сервіс)
- Modify: `App/Sources/MenuBarView.swift:23-24, 54, 70`
- Modify: `App/Sources/STLTHRecorderApp.swift:8-19, 64`
- Modify: `App/Sources/SettingsView.swift` (секції «Записи» і «Транскрибація»)

**Interfaces:**
- Consumes: `SerialTaskQueue`, `TranscriptionPipeline.run`, `Transcriber.isAvailable`,
  `SessionMixer.mixExists(in:)`.
- Produces: `TranscriptionService.inProgress`, `isTranscribing(_:)`, `hasTranscript(_:)`,
  `hasAudio(_:)`, `transcriptURL(for:)`, `transcribeAfterRecording(_:)`, `transcribe(_:announce:)`.

- [ ] **Step 1: Сервіс**

```swift
import AppKit
import Foundation
import RecorderCore
import SwiftUI

/// Transcribes sessions in the background, one at a time.
///
/// Lives in the app layer for the same reason `MixdownService` does: whether to
/// transcribe at all, and whether to delete the audio afterwards, are settings, and
/// the core has no business reading `@AppStorage`.
///
/// A failed transcription never makes a session look unsuccessful: the audio is still
/// there and the transcript can always be made again from the menu. The automatic
/// path logs and moves on; only a run the user started by hand gets an alert.
@MainActor
final class TranscriptionService: ObservableObject {

    /// Sessions queued or running, so the menu can say so.
    @Published private(set) var inProgress: Set<UUID> = []

    @AppStorage("autoTranscribe") var isEnabled = true
    @AppStorage("deleteAudioAfterTranscription") var deletesAudio = false

    private let store: SessionStore
    private let queue = SerialTaskQueue()

    init(store: SessionStore) {
        self.store = store
    }

    func isTranscribing(_ meta: SessionMeta) -> Bool {
        inProgress.contains(meta.sessionId)
    }

    func hasTranscript(_ meta: SessionMeta) -> Bool {
        FileManager.default.fileExists(atPath: transcriptURL(for: meta).path)
    }

    /// Whether either source track is still on disk. Once both are gone there is
    /// nothing to transcribe or to mix, and the menu must not promise otherwise.
    func hasAudio(_ meta: SessionMeta) -> Bool {
        let dir = directory(for: meta)
        return ["mic.caf", "system.caf"].contains {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    func transcriptURL(for meta: SessionMeta) -> URL {
        directory(for: meta).appendingPathComponent("transcript.md")
    }

    /// Transcribe automatically after a session is finished.
    ///
    /// Quiet when the models are absent: the offer to install them lives in the session
    /// menu, and must not pop up after every recording. Quiet, too, when a transcript
    /// already exists — a recovered session may have been transcribed before the crash.
    func transcribeAfterRecording(_ meta: SessionMeta?) {
        guard isEnabled, let meta, Transcriber.isAvailable, !hasTranscript(meta) else { return }
        transcribe(meta, announce: false)
    }

    /// Transcribe on demand, from the menu, or automatically with `announce: false`.
    func transcribe(_ meta: SessionMeta, announce: Bool = true) {
        guard !inProgress.contains(meta.sessionId) else { return }
        inProgress.insert(meta.sessionId)

        let dir = directory(for: meta)
        Task { [store, queue] in
            let job = await queue.enqueue {
                try TranscriptionPipeline.run(sessionDir: dir, store: store,
                                              deleteAudio: { Self.mayDeleteAudio(in: dir) })
            }
            do {
                let result = try await job.value
                inProgress.remove(meta.sessionId)
                if announce { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
            } catch {
                inProgress.remove(meta.sessionId)
                NSLog("Транскрипт не створено: %@", error.localizedDescription)
                if announce {
                    let alert = NSAlert()
                    alert.messageText = "Не вдалося транскрибувати"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    /// The deletion decision, read when whisper has finished rather than when the job
    /// was queued, and read straight from defaults because it runs off the main actor.
    ///
    /// The mixdown is a second guard. It is built concurrently with transcription, and
    /// on a very short recording could still be encoding when the transcript lands —
    /// deleting the tracks under it would leave the session with no listening copy at
    /// all. So while mixdowns are on, the audio goes only once `session.m4a` exists.
    nonisolated private static func mayDeleteAudio(in dir: URL) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "deleteAudioAfterTranscription") else { return false }
        let mixdownEnabled = defaults.object(forKey: "createMixdown") as? Bool ?? true
        return !mixdownEnabled || SessionMixer.mixExists(in: dir)
    }

    private func directory(for meta: SessionMeta) -> URL {
        store.root.appendingPathComponent(meta.sessionId.uuidString, isDirectory: true)
    }
}
```

- [ ] **Step 2: Меню**

`RecentSessionsMenu`: додати `@ObservedObject var transcription: TranscriptionService`,
видалити `@State transcribing`, `@State transcriptionError`, `hasTranscript`, `transcribe`.
`revealTranscript` → `NSWorkspace.shared.activateFileViewerSelecting([transcription.transcriptURL(for: meta)])`.

```swift
    @ViewBuilder
    private func listenButton(for meta: SessionMeta) -> some View {
        if mixdown.isMixing(meta) {
            Text("Зводиться…")
        } else if mixdown.hasMix(for: meta) {
            Button("Прослухати розмову") { NSWorkspace.shared.open(mixdown.mixURL(for: meta)) }
        } else if transcription.hasAudio(meta) {
            // Sessions recorded before mixdowns existed, or ones whose mix failed.
            Button("Створити зведений файл") { mixdown.mix(meta) }
        } else {
            // Not a broken session: the tracks were removed on purpose after
            // transcription, and there is nothing left to mix from.
            Text("Аудіо видалено після транскрибації")
        }
    }

    @ViewBuilder
    private func transcribeButton(for meta: SessionMeta) -> some View {
        if transcription.isTranscribing(meta) {
            Text("Транскрибується…")
        } else if transcription.hasTranscript(meta) {
            Button("Показати транскрипт") { revealTranscript(meta) }
        } else if !transcription.hasAudio(meta) {
            // Offering transcription here would promise what can no longer be done.
            EmptyView()
        } else if Transcriber.isAvailable {
            Button("Транскрибувати") { transcription.transcribe(meta) }
        } else if case .downloading(_, let completed, let total) = models.state {
            Text("Завантаження моделей — \(Int(Double(completed) / Double(max(total, 1)) * 100))%")
        } else {
            Button("Увімкнути транскрибацію…") {
                bringAppToFront()
                openWindow(id: TranscriptionSetupWindow.id)
            }
        }
    }
```

- [ ] **Step 3: Точка авто-запуску та прокидання**

`MenuBarView`: `@ObservedObject var transcription: TranscriptionService`; після
`mixdown.mixAfterRecording(controller.lastCompletedMeta)`:

```swift
                    // Same rule as the mixdown: derived, in the background, one session
                    // at a time — a recording that ends while another is still being
                    // recognised simply joins the queue.
                    transcription.transcribeAfterRecording(controller.lastCompletedMeta)
```

`RecentSessionsMenu(controller: controller, models: models, mixdown: mixdown, transcription: transcription)`.

`STLTHRecorderApp`: `@StateObject private var transcription = TranscriptionService(store: SessionStore())`;
передати в `MenuBarView(..., transcription: transcription)`.

- [ ] **Step 4: Налаштування**

`SettingsView`: `@AppStorage("autoTranscribe") private var autoTranscribe = true`,
`@AppStorage("deleteAudioAfterTranscription") private var deleteAudio = false`.

У секції «Записи» підпис під тумблером зведення змінити хвіст:
«Вихідні mic.caf і system.caf лишаються недоторканими, якщо не увімкнено видалення після розпізнавання.»

У секції «Транскрибація», перед `LabeledContent("Моделі розпізнавання")`:

```swift
                Toggle("Розпізнавати мову після кожного запису", isOn: $autoTranscribe)
                Text("Працює у фоні й повністю на цьому Mac — по одній сесії за раз. "
                     + "Займає приблизно стільки ж часу, скільки тривала розмова.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if autoTranscribe && !Transcriber.isAvailable {
                    // The toggle stays available, but without models it does nothing —
                    // better to say so here than let the user wait for a transcript
                    // that will not come.
                    Text("Спершу завантажте моделі — нижче або в меню будь-якої сесії.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Toggle("Видаляти аудіо після розпізнавання", isOn: $deleteAudio)
                Text("Вихідні mic.caf і system.caf видаляються назавжди; лишаються транскрипт, "
                     + "зведений файл і meta.json. Година розмови — це ~990 МБ проти ~43 МБ. "
                     + "Спрацьовує лише тоді, коли в транскрипті є мовлення.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if deleteAudio && !createMixdown {
                    // Together with the mixdown off this leaves nothing of a session but
                    // text. A legitimate choice — but one to make with open eyes, not to
                    // discover a week later.
                    Text("Зведений файл вимкнено — після видалення доріжок від сесії лишиться тільки текст.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
```

- [ ] **Step 5: Коміт, пуш, CI (перевіряє лише, що ядро не зламано)**

```bash
git add App/Sources
git commit -m "feat(app): transcribe automatically after every recording"
git push && gh run watch $(gh run list --limit 1 --json databaseId -q '.[0].databaseId') --exit-status
```

---

### Task 5: large-v3 замість turbo, прибирання застарілої моделі

**Files:**
- Modify: `RecorderCore/Sources/RecorderCore/ModelInstaller.swift:20-26, 68-84, 184-193, 197-211`
- Modify: `RecorderCore/Sources/RecorderCore/Transcriber.swift:67-126`
- Modify: `RecorderCore/Tests/RecorderCoreTests/ModelInstallerTests.swift`
- Modify: `scripts/setup-transcription.sh:17, 47-49`
- Modify: `App/Sources/TranscriptionSetupWindow.swift:60` (коментар), `App/Sources/SettingsView.swift` (підказка про стару модель)
- Modify: `docs/design/specs/2026-08-10-transcription-setup.md` (числа)

**Передумова — виконано 2026-09-04:** файл завантажено повністю (curl, 1 081 140 203 Б)
і захешовано: `sha256sum` = `d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1`.
Збігається з `X-Linked-ETag` HuggingFace і з числом у завданні. Task 6 перевіряє той
самий digest ще раз через реальний `ModelInstaller.httpFetch` на ранері.

**Interfaces:**
- Produces: `ModelInstaller.supersededModels: [String]`;
  `ModelInstaller.removeSuperseded(in:)` (internal static);
  `ModelInstaller.downloadAll(into:models:fetch:progress:)` з `models` за замовчуванням `requiredModels`.

- [ ] **Step 1: Падаючі тести**

Замінити `sizeMatchesModels`:

```swift
    @Test("The advertised download size matches what is actually fetched")
    func sizeMatchesModels() {
        let sum = ModelInstaller.requiredModels.reduce(Int64(0)) { $0 + $1.bytes }
        #expect(ModelInstaller.totalBytes == sum)
        #expect(sum == 1_082_025_301)

        // README and `ls -lh` speak in binary units — 1 031 МБ for the speech model,
        // 1.01 ГБ for both. `ByteCountFormatter.file` is decimal and would say 1,08 ГБ,
        // so the UI must use the binary style or the number the user agrees to
        // stops matching the number the project documents. The decimal separator is
        // the runner's locale, hence both spellings.
        let shown = ByteCountFormatter.string(fromByteCount: sum, countStyle: .binary)
        #expect(shown.contains("1.01") || shown.contains("1,01"))
    }
```

Додати в `// MARK: - Removal`:

```swift
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
        let errorPage = Data("<html>502</html>".utf8)

        await #expect(throws: ModelInstaller.InstallerError.self) {
            try await ModelInstaller.downloadAll(into: dir, models: [model],
                                                 fetch: self.fetch(errorPage), progress: { _, _ in })
        }

        #expect(FileManager.default.fileExists(atPath: turbo.path))
    }

    @Test("Deleting the models takes a leftover turbo file with them")
    @MainActor
    func removalIncludesSuperseded() throws {
        let dir = try makeDirectory()
        let installer = ModelInstaller(directory: dir, fetch: { _, _, _ in })
        let turbo = dir.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
        try Data("x".utf8).write(to: turbo)

        try installer.removeModels()

        #expect(!FileManager.default.fileExists(atPath: turbo.path))
    }

    @Test("The old model still counts for Transcriber until it is replaced")
    func turboRemainsACandidate() {
        // A machine that has not re-downloaded keeps transcribing on turbo; the new
        // model simply wins when both are present.
        let dir = ModelInstaller.defaultDirectory
        let candidates = Transcriber.modelCandidates
        let new = candidates.firstIndex(of: dir.appendingPathComponent("ggml-large-v3-q5_0.bin").path)
        let old = candidates.firstIndex(of: dir.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin").path)
        #expect(new != nil && old != nil && new! < old!)
    }
```

- [ ] **Step 2: Реалізація `ModelInstaller`**

`requiredModels[0]`:

```swift
        // Full large-v3, not turbo. Turbo is twice as fast because its decoder is
        // distilled from 32 layers to 4 — and the decoder is what turns tokens into a
        // sentence that holds together. The Windows build observed this directly on
        // Ukrainian: turbo produced «Тораз глянемо» where the full model hears «Та
        // розглянемо», and fragments where it hears words. Transcription is a
        // background job after the call, so twice the time costs less than mangled
        // lines. No WER was measured for this model here — see README.
        Model(name: "ggml-large-v3-q5_0.bin",
              url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin")!,
              bytes: 1_081_140_203,
              sha256: "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1",
              purpose: "розпізнавання мовлення"),
```

Коментар над масивом: «Sizes and digests: large-v3 measured 2026-09-04 by downloading the
file and hashing it; VAD measured 2026-08-10.»

Після `requiredModels`:

```swift
    /// Models an earlier version installed and this one no longer uses. Leaving them
    /// in place means keeping half a gigabyte nobody will open again — but they are
    /// removed only once their replacement has downloaded and verified, so a dropped
    /// download never leaves the user with no working model at all.
    nonisolated public static let supersededModels = ["ggml-large-v3-turbo-q5_0.bin"]

    nonisolated static func removeSuperseded(in directory: URL) {
        for name in supersededModels {
            let file = directory.appendingPathComponent(name)
            // Busy or unreadable: it simply stays. Not worth failing an install over.
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.appendingPathExtension("part"))
        }
    }
```

`downloadAll`:

```swift
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
        // Reached only when every model above verified — a throw skips this on purpose.
        removeSuperseded(in: directory)
    }
```

`removeModels()`: після циклу по `requiredModels` — `Self.removeSuperseded(in: directory)`.
Doc-коментар до `Model` (рядок 24): `ggml-large-v3-turbo-q5_0.bin` → `ggml-large-v3-q5_0.bin`.

- [ ] **Step 3: `Transcriber`**

`modelCandidates`: `let names = ["ggml-large-v3-q5_0.bin", "ggml-large-v3-turbo-q5_0.bin", "ggml-medium-q5_0.bin"]`.
`modelSearchHint = "~/dev/models/ggml-large-v3-q5_0.bin"`.
До таблиці в doc-коментарі додати перший рядок і абзац:

```
    /// | `large-v3-q5_0` | 1 031 МБ | не міряно | не міряно | не міряно |
    ...
    /// `large-v3-q5_0` sits first since 1.3.0 and is what the installer fetches; turbo
    /// stays a candidate so a machine that has not re-downloaded keeps working. Its
    /// numbers above are missing because they were never measured on this bench — the
    /// switch follows the Windows build's observation on Ukrainian, not a WER run.
```

- [ ] **Step 4: Скрипт, вікно, налаштування, spec**

`scripts/setup-transcription.sh`: `SPEECH="ggml-large-v3-q5_0.bin"  # розпізнавання, ~1 031 МБ`;
`fetch "$SPEECH" "$BASE/$SPEECH" "1 031 МБ"`; після обох `fetch`:

```zsh
# The model 1.2.0 used. Removed only now, after both downloads above succeeded.
rm -f "$MODELS/ggml-large-v3-turbo-q5_0.bin"
```

`TranscriptionSetupWindow.swift:60`: «864 KB against 547 MB» → «864 KB against 1 031 MB».

`SettingsView` секція «Транскрибація», під `LabeledContent("Моделі розпізнавання")`:

```swift
                if models.state == .notInstalled, Transcriber.isAvailable {
                    // 1.2.0 shipped turbo. It still works, so nothing is broken — but
                    // the person should know a download is being asked for a reason.
                    Text("Знайдено попередню модель (turbo) — розпізнавання працює на ній. "
                         + "Після завантаження нової стара зітреться сама.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
```

`docs/design/specs/2026-08-10-transcription-setup.md`: усі «548 МБ» → «1,01 ГБ (1 031 МБ)»,
рядок 45 назви моделі → `large-v3-q5_0`, у відкритому питанні (рядки 214-215) дописати:
«Вирішено 04.09.2026: типова модель — повна large-v3; turbo лишається запасною.»

- [ ] **Step 5: Коміт, пуш, CI**

```bash
git add RecorderCore App/Sources scripts docs/design/specs
git commit -m "feat(core): switch to large-v3 and retire the turbo model"
git push && gh run watch $(gh run list --limit 1 --json databaseId -q '.[0].databaseId') --exit-status
```

---

### Task 6: End-to-end на ранері — справжній whisper, справжня модель

**Files:**
- Create: `Tools/e2e-transcription/main.swift`
- Create: `.github/workflows/e2e-transcription.yml` (`workflow_dispatch`)
- Modify: `Makefile` (ціль `e2e-transcription`, за зразком `recorder-cli`)

**Interfaces:**
- Consumes: `ModelInstaller.downloadAll(into:fetch:progress:)` з `ModelInstaller.httpFetch`,
  `SessionStore.begin/complete`, `TranscriptionPipeline.run`, `Transcriber.tool()`.

Що доводить прогін (кожен пункт — `precondition`, червоний ранер = провал):
1. Реальне завантаження обох моделей через `ModelInstaller.downloadAll` у тимчасову
   теку, де заздалегідь лежить файл-підробка `ggml-large-v3-turbo-q5_0.bin` → digest
   large-v3 збігся з пінованим, turbo зникла **після** завантаження.
2. Сесія з синтезованою мовою (`say -v Lesya`, якщо голос є на ранері, інакше
   англійський голос і `language: "en"`), `afconvert` → `mic.caf` 48 кГц моно та
   `system.caf` 48 кГц стерео, `meta.json` через `SessionStore`. `TranscriptionPipeline.run`
   із `deleteAudio: { true }` → `hadSpeech == true`, `transcript.md` містить хоч один
   рядок з таймкодом, `mic.caf`/`system.caf` зникли, `session.m4a`-заглушка на місці,
   `audioRemovedAt != nil`.
3. Сесія з 10 с тиші → `hadSpeech == false`, доріжки на місці, `audioRemovedAt == nil`.
4. Дві сесії, поставлені в `SerialTaskQueue` поспіль → у логах whisper другий процес
   стартує після завершення першого (перевіряється мітками часу навколо `run`).

- [ ] **Step 1: Харнес**

```swift
// Tools/e2e-transcription/main.swift
//
// The one test that runs whisper for real. Everything else in the suite stubs the
// model out, which proves the plumbing and nothing about the model file itself —
// whether whisper-cli v1.9.2 opens ggml-large-v3-q5_0.bin, whether its output has
// the JSON shape `segments(at:)` parses, whether "speech" is actually detected.
// Built with swiftc against the core sources (see Makefile) and run on the CI Mac
// runner via .github/workflows/e2e-transcription.yml. Exits non-zero on any failure.
import Foundation
import RecorderCore

func check(_ condition: Bool, _ message: String) {
    guard !condition else { print("  ✅ \(message)"); return }
    print("  ❌ \(message)")
    exit(1)
}

func run(_ launchPath: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "e2e", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "\(launchPath) \(arguments) → \(process.terminationStatus)"])
    }
}

let work = FileManager.default.temporaryDirectory
    .appendingPathComponent("stlth-e2e-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

// MARK: 1. Real download into the directory Transcriber searches first

let models = ModelInstaller.defaultDirectory
try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
let fakeTurbo = models.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
try Data("stale".utf8).write(to: fakeTurbo)

print("==> Downloading \(ModelInstaller.totalBytes) bytes of models")
try await ModelInstaller.downloadAll(into: models, fetch: ModelInstaller.httpFetch) { file, done in
    if done % (100 << 20) < (1 << 20) { print("    \(file): \(done >> 20) MB") }
}
check(ModelInstaller.isInstalled(in: models), "both models present at their pinned size and digest")
check(!FileManager.default.fileExists(atPath: fakeTurbo.path), "superseded turbo removed after the replacement verified")
check(Transcriber.tool() != nil, "whisper-cli found next to this binary")
check(Transcriber.model()?.hasSuffix("ggml-large-v3-q5_0.bin") == true, "large-v3 is the model Transcriber picks")

// MARK: 2. A session with speech

let voice = ProcessInfo.processInfo.environment["E2E_VOICE"] ?? "Lesya"
let language = ProcessInfo.processInfo.environment["E2E_LANGUAGE"] ?? "uk"
let text = language == "uk"
    ? "Доброго дня. Сьогодні ми обговоримо структуру вашого портфеля та цілі на найближчі три роки."
    : "Good afternoon. Today we will discuss the structure of your portfolio and your goals for the next three years."

let aiff = work.appendingPathComponent("speech.aiff")
try run("/usr/bin/say", ["-v", voice, "-o", aiff.path, text])

let store = SessionStore(root: work.appendingPathComponent("Sessions", isDirectory: true))
try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)

func makeSession(from source: URL?) throws -> SessionHandle {
    let handle = try store.begin(consentAt: Date())
    let mic = handle.dir.appendingPathComponent("mic.caf")
    let system = handle.dir.appendingPathComponent("system.caf")
    if let source {
        try run("/usr/bin/afconvert", ["-f", "caff", "-d", "LEI16@48000", "-c", "1", source.path, mic.path])
        try run("/usr/bin/afconvert", ["-f", "caff", "-d", "LEI16@48000", "-c", "2", source.path, system.path])
    } else {
        // Ten seconds of digital silence on both tracks.
        let silence = work.appendingPathComponent("silence.wav")
        try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@48000", "-c", "1",
                                        "-o", silence.path, "/dev/null"])
        try run("/usr/bin/afconvert", ["-f", "caff", "-d", "LEI16@48000", "-c", "1", silence.path, mic.path])
        try run("/usr/bin/afconvert", ["-f", "caff", "-d", "LEI16@48000", "-c", "2", silence.path, system.path])
    }
    try Data("stand-in".utf8).write(to: handle.dir.appendingPathComponent("session.m4a"))
    try store.complete(handle, result: RecordingResult(
        micURL: mic, systemURL: system, durationMs: 10_000,
        inputDeviceName: "e2e", outputDeviceName: "e2e"))
    return handle
}

print("==> Transcribing speech with large-v3")
let spoken = try makeSession(from: aiff)
let started = Date()
let result = try TranscriptionPipeline.run(sessionDir: spoken.dir, store: store,
                                           deleteAudio: { true },
                                           transcribe: { try Transcriber.transcribe(sessionDir: $0, language: language) })
print("    took \(Int(Date().timeIntervalSince(started))) s")
let transcript = try String(contentsOf: result.url, encoding: .utf8)
print(transcript)
check(result.hadSpeech, "speech detected")
check(transcript.contains("`[00:00:"), "transcript has at least one timestamped line")
check(!FileManager.default.fileExists(atPath: spoken.dir.appendingPathComponent("mic.caf").path), "mic.caf removed")
check(!FileManager.default.fileExists(atPath: spoken.dir.appendingPathComponent("system.caf").path), "system.caf removed")
check(FileManager.default.fileExists(atPath: spoken.dir.appendingPathComponent("session.m4a").path), "session.m4a kept")
check(try SessionMeta.load(from: spoken.dir.appendingPathComponent("meta.json")).audioRemovedAt != nil, "audioRemovedAt recorded")

// MARK: 3. A silent session keeps its audio

print("==> Transcribing silence")
let silent = try makeSession(from: nil)
let quiet = try TranscriptionPipeline.run(sessionDir: silent.dir, store: store,
                                          deleteAudio: { true },
                                          transcribe: { try Transcriber.transcribe(sessionDir: $0, language: language) })
check(!quiet.hadSpeech, "no speech in silence")
check(FileManager.default.fileExists(atPath: silent.dir.appendingPathComponent("mic.caf").path), "silent session keeps mic.caf")
check(try SessionMeta.load(from: silent.dir.appendingPathComponent("meta.json")).audioRemovedAt == nil, "silent session not marked as stripped")

// MARK: 4. Two sessions through the queue never overlap

print("==> Two sessions through SerialTaskQueue")
let a = try makeSession(from: aiff)
let b = try makeSession(from: aiff)
let queue = SerialTaskQueue()
actor Stamps { var list: [(String, Date)] = []; func add(_ s: String) { list.append((s, Date())) } }
let stamps = Stamps()
let first = await queue.enqueue {
    await stamps.add("A start")
    _ = try TranscriptionPipeline.run(sessionDir: a.dir, store: store, deleteAudio: { false },
                                      transcribe: { try Transcriber.transcribe(sessionDir: $0, language: language) })
    await stamps.add("A end")
}
let second = await queue.enqueue {
    await stamps.add("B start")
    _ = try TranscriptionPipeline.run(sessionDir: b.dir, store: store, deleteAudio: { false },
                                      transcribe: { try Transcriber.transcribe(sessionDir: $0, language: language) })
    await stamps.add("B end")
}
try await first.value
try await second.value
let order = await stamps.list.map(\.0)
check(order == ["A start", "A end", "B start", "B end"], "B started only after A finished: \(order)")

try? FileManager.default.removeItem(at: work)
print("✅ end-to-end transcription passed")
```

`Makefile`:

```make
## Real-whisper end-to-end check, run on the CI Mac runner (see e2e-transcription.yml)
e2e-transcription: app
	@mkdir -p $(BUILD_DIR)/e2e
	swiftc -O -parse-as-library RecorderCore/Sources/RecorderCore/*.swift Tools/e2e-transcription/main.swift \
	  -o $(BUILD_DIR)/e2e/e2e-transcription \
	  -framework CoreAudio -framework AVFoundation
	cp build/whisper/whisper-cli $(BUILD_DIR)/e2e/whisper-cli
	$(BUILD_DIR)/e2e/e2e-transcription
```

Примітка: `main.swift` з top-level `await` потребує `@main`-стилю або `-parse-as-library`
не підходить для top-level коду — у реалізації загорнути тіло в `@main struct E2E { static func main() async throws }`
і зібрати без `-parse-as-library`-конфлікту (перевірити на ранері; це єдиний крок, де
компіляція харнеса може впасти — тоді правити харнес, не ядро).

- [ ] **Step 2: Workflow**

```yaml
name: e2e-transcription

# Runs whisper for real on the CI Mac: downloads the pinned models through the app's
# own installer, synthesises speech with `say`, transcribes it with large-v3 and
# checks the audio-removal pipeline end to end. Manual, because it pulls a gigabyte.

on:
  workflow_dispatch:

jobs:
  e2e:
    name: Real whisper on macos-15
    runs-on: macos-15
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v4
      - name: Cache whisper-cli
        uses: actions/cache@v4
        with:
          path: build/whisper
          key: whisper-cli-${{ runner.os }}-${{ hashFiles('scripts/build-whisper.sh') }}
      - name: Pick a voice the runner actually has
        id: voice
        run: |
          if say -v '?' | grep -q '^Lesya'; then
            echo "voice=Lesya" >> "$GITHUB_OUTPUT"; echo "language=uk" >> "$GITHUB_OUTPUT"
          else
            echo "voice=Samantha" >> "$GITHUB_OUTPUT"; echo "language=en" >> "$GITHUB_OUTPUT"
          fi
      - name: Build and run the harness
        env:
          E2E_VOICE: ${{ steps.voice.outputs.voice }}
          E2E_LANGUAGE: ${{ steps.voice.outputs.language }}
        run: make e2e-transcription
```

- [ ] **Step 3: Коміт, пуш, запуск, очікування**

```bash
git add Tools/e2e-transcription Makefile .github/workflows/e2e-transcription.yml
git commit -m "ci: end-to-end transcription on the runner"
git push
gh workflow run e2e-transcription.yml && sleep 20
gh run watch $(gh run list --workflow=e2e-transcription.yml --limit 1 --json databaseId -q '.[0].databaseId') --exit-status
```

Якщо червоно — читати лог (`gh run view <id> --log-failed`), правити, повторювати.
Результат прогону (тривалість транскрибації, рядки транскрипту) — у `docs/notes/evidence/e2e-large-v3-runner.txt`
і посилання з ENGINEERING_NOTES §13.

---

### Task 7: Документація (після рішення користувача щодо WER-числа)

**Files:**
- Modify: `README.md:23, 60-100`
- Modify: `docs/ENGINEERING_NOTES.md` — §10 (примітка), новий §13

- [ ] **Step 1: README**

Рядок 23 таблиці: `| Бонус | Локальна транскрибація (whisper.cpp) — автоматично після запису, повністю на пристрої |`.

Розділ «Локальна транскрибація» — новий текст (перший абзац):

```
Після кожного запису транскрипт робиться сам, у фоні, по одній сесії за раз
(вимикається в налаштуваннях). Руками — `Останні записи` → сесія →
**Транскрибувати**. Працює на whisper.cpp повністю на пристрої; аудіо нікуди не
вивантажується. Якщо моделей немає, автоматично нічого не відбувається і ніхто не
питає — пропозиція завантажити їх живе в меню сесії.
```

Абзац про WER — за вибраним варіантом (див. нижче).

Новий підрозділ після таблиці моделей:

```
### Видалення аудіо після транскрибації

Вимкнено за замовчуванням. Якщо увімкнути в налаштуваннях, після успішної
транскрибації вихідні `mic.caf` і `system.caf` видаляються **безповоротно**;
лишаються `transcript.md`, `session.m4a` і `meta.json` (у ньому — `audioRemovedAt`,
щоб сесія без аудіо не виглядала пошкодженою). Година розмови — це ~990 МБ доріжок
проти ~43 МБ зведення.

Два запобіжники: доріжки не чіпаються, якщо транскрипт порожній (розпізнавання
нічого не знайшло — це привід зберегти аудіо, а не позбутися його), і не чіпаються,
поки не готовий зведений файл, якщо зведення увімкнене. Якщо зведення вимкнене —
від сесії лишиться тільки текст; налаштування про це попереджають.
```

Таблиця моделей: `| ggml-large-v3-q5_0.bin | 1 031 МБ | розпізнавання |`; «близько 548 МБ» →
«близько 1 ГБ (1 031 МБ)». Абзац: «Turbo-модель із 1.2.0 продовжує працювати, поки нову
не завантажено; після успішного завантаження вона видаляється сама.»

- [ ] **Step 2: ENGINEERING_NOTES**

§10, після таблиці «Без VAD / З VAD» — примітка за вибраним варіантом. У «Чого ще не
пробували»: `large-v3` без turbo → «з 1.3.0 відвантажується, але WER не міряно».

Новий §13 «Автотранскрибація, видалення аудіо, large-v3» із розвилками:
- **Чому черга, а не паралель** — CPU ≈ тривалість розмови на канал; два whisper
  поспіль на машині людини, яка щойно поклала слухавку. `actor` + ланцюжок задач, не
  семафор (у Swift concurrency немає блокуючого примітиву, безпечного через `await`).
- **Чому один конвеєр для авто й ручного шляху** — та сама опція видалення має
  поводитися однаково.
- **Чому видаляти тільки за наявності мови, і тільки після зведення** — порожній
  транскрипт = розпізнавання не спрацювало; зведення будується паралельно.
- **Чому large-v3 замість turbo, і що з числом 8.8 %** — спостереження Windows-збірки
  («Тораз глянемо» / «Та розглянемо»), ціна ×2–3 часу у фоні; всі виміри §10 зроблені
  на turbo; переміряти без Mac неможливо; `Tools/wer-live.sh` — інструкція для того,
  хто переміряє.
- **Що перевірено і чим** — ядро: `swift test` на CI; SwiftUI-шар: компіляція і
  лінкування бандла на CI (Task 0); whisper + large-v3 + видалення аудіо: прогін
  `e2e-transcription.yml` на ранері (Task 6, артефакт у `docs/notes/evidence/`).
- **Що НЕ перевірено** — поведінка меню і налаштувань очима (ніхто не клікав),
  запис на живому Mac з 1.3.0, WER large-v3 на живій українській.

- [ ] **Step 3: Коміт, пуш**

```bash
git add README.md docs/ENGINEERING_NOTES.md
git commit -m "docs: describe auto-transcription, audio removal and large-v3"
git push
```

---

### Task 8: Версія 1.3.0

- [ ] `project.yml:21-22, 37-38` → `"1.3.0"`, `"4"`; `App/Info.plist:20, 22` → `1.3.0`, `4`.
- [ ] `grep -n "1\.2\.0\|\"3\"" project.yml App/Info.plist` — не має лишитися.
- [ ] Коміт `chore: bump version to 1.3.0 (build 4)`, пуш, CI зелений.
- [ ] Реліз **не** запускати.

---

## WER-число: два варіанти формулювання (потрібне рішення)

**Варіант A — зняти число, сказати прямо, що не міряно.**

README, розділ «Локальна транскрибація»:
> Якість large-v3 на живій українській **не міряна**: у 1.3.0 модель замінено з
> розрахунку на спостереження Windows-збірки (turbo ліпив «Тораз глянемо» там, де
> повна модель чує «Та розглянемо»), а не на власний вимір. Попередня модель
> (large-v3-turbo) давала 8.8 % WER без урахування формату чисел — методика в
> ENGINEERING_NOTES §10; для large-v3 очікується не гірше, але це очікування, не
> вимір.

**Варіант B — лишити число з явною позначкою.**

README:
> Виміряна якість на живій українській крізь Zoom — **8.8 % WER** (без урахування
> формату чисел) — **стосується попередньої моделі large-v3-turbo**, на якій робилися
> всі виміри. Модель large-v3, яку встановлює 1.3.0, на цьому стенді не переміряна.

В обох варіантах у таблиці на початку README число прибирається (комірка не вміщує
застереження), а ENGINEERING_NOTES §10 отримує датовану примітку: «Усі числа в цьому
розділі виміряні на `large-v3-turbo-q5_0`. З 1.3.0 типова модель — `large-v3-q5_0`; її
WER не міряно.»

**Рекомендація:** A. Число, яке не описує відвантажуване, у README швидше вводить в
оману, ніж інформує; в ENGINEERING_NOTES воно лишається як історія вимірювання.
