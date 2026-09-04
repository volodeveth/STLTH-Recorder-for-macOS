# STLTH Recorder for macOS Implementation Plan

> Кроки позначені чекбоксами (`- [ ]`) — план виконується задача за задачею.

**Goal:** Нативний macOS menu bar застосунок, що записує зустріч у два синхронні аудіофайли (мікрофон = радник, системний звук = клієнт) без бота в дзвінку, з production-якістю і бонус-шаром (транскрибація).

**Architecture:** Global Core Audio process tap + мікрофон в одному aggregate device (один годинник → синхронність за побудовою). SwiftUI `MenuBarExtra` поверх SPM-пакета `RecorderCore` (headless, тестований). Референс робочого коду CoreAudio — AudioCap (клонується в Task 3).

**Tech Stack:** Swift 5.10+, SwiftUI, CoreAudio (process taps, macOS 14.4+), AVFoundation (AVAudioFile), XcodeGen, GitHub Actions (macos-15 arm), BlackHole (тільки дев-стенд), whisper.cpp (бонус).

**Spec:** `docs/design/specs/2026-08-06-stlth-recorder-design.md`

## Global Constraints

- Платформа: macOS 14.4+ (Apple Silicon); цільові версії тестування 15 і 26.
- Мова UI — **українська**. Назва: STLTH Recorder for macOS.
- Menu bar agent: `LSUIElement = true` (без Dock), автозапуск через `SMAppService` (перемикається).
- У продукті ЗАБОРОНЕНО: віртуальні аудіодрайвери, системні розширення, будь-що з правами адміністратора. (BlackHole — лише тестовий стенд, ніколи не залежність застосунку.)
- Формат запису: CAF / LPCM 16-bit, 48000 Гц; `mic.caf` — 1 канал, `system.caf` — 2 канали.
- Тека сесій: `~/Library/Application Support/STLTHRecorder/Sessions/<UUID>/`.
- Інваріант таймлайна: у кожному файлі семплів = тривалість × 48000; тиша пишеться, не вирізається.
- Аудіо нікуди не вивантажується; жодних мережевих запитів у застосунку (крім ручного «Перевірити оновлення» в P5).
- Розбіжність каналів < 300 мс за 60 хв (перевіряється drift-check'ом).
- Виконання: Task 1 — людина (оплата, реєстрація). Tasks 2–16 — на орендованому Mac через Remote SSH. Комміти — Conventional Commits, після кожного зеленого кроку.

---

### Task 0: Prework без мака (Windows, поки триває верифікація провайдера)

Виконується у Windows-теці проєкту, БЕЗ Swift-тулчейна. Мета: коли з'явиться мак,
перший день починається одразу з воріт (Tasks 3/6), а не з конфігів. Результати кладуться
за фінальними шляхами репо (RecorderCore/, Tools/, docs/) — Task 2 Step 5 переносить їх
на мак разом із docs/.

**Files:**
- Create: `docs/notes/audiocap-findings.md`, `Tools/gen_clicks.py`, `Tools/drift_check.py`,
  `RecorderCore/**` (Package.swift + TimelineAccountant + тести), `project.yml`, `Makefile`,
  `.github/workflows/ci.yml`, `README.md` (скелет), `docs/ENGINEERING_NOTES.md` (каркас)

- [x] **Step 1: Конспект AudioCap з GitHub (пів-Task 3).** Прочитати джерела
  https://github.com/insidegui/AudioCap (WebFetch raw-файлів: ProcessTap.swift,
  AudioRecorder.swift, entitlements/Info.plist) → `docs/notes/audiocap-findings.md`:
  точні виклики CATapDescription / AudioHardwareCreateProcessTap /
  AudioHardwareCreateAggregateDevice (ключі словника), формат IO-колбека, TCC-патерн,
  usage-ключ для system audio. Позначити зверху: «НЕ перевірено на залізі — GATE-1 (Task 3
  Step 2) лишається обов'язковим».
- [x] **Step 2: drift-інструменти (Task 13 Step 1) + локальна перевірка на Windows.**
  Написати `gen_clicks.py` і `drift_check.py` за описом Task 13. Тест без мака: згенерувати
  clicks.wav; зробити з нього пару (mic/system) зі штучним зсувом 150 мс → drift_check
  показує ~150 мс, exit 0; зсув 400 мс → exit 1. Python на Windows: `py -3 -m pip install numpy soundfile`.
- [x] **Step 3: Конфіги з Task 4** (код там): `RecorderCore/Package.swift`, `project.yml`,
  `Makefile`, `.gitignore`, `.github/workflows/ci.yml`. Не запускаються тут — перший
  `make gen build` на маку (Task 4 Step 5).
- [x] **Step 4: TimelineAccountant + тести з Task 5** (код там, чистий Swift stdlib).
  Написати файли; перший запуск `swift test` — на маку (Task 5 Steps 2/4).
- [x] **Step 5: Скелети документів:** `README.md` — структура + порожня приймальна матриця
  (критерії ТЗ №1–6 → кроки → результат → дата); `docs/ENGINEERING_NOTES.md` — розвилки
  зі спеки §1 (global tap vs per-process vs ScreenCaptureKit; aggregate device;
  інваріант таймлайна) як чернетка.
- [x] **Step 6:** Commit у Windows-репо: `docs: prework (audiocap conspectus, drift tools, config skeletons)`.
  Позначити виконані частини Tasks 4/5/13 у цьому файлі як done-in-prework (примітка, не чекбокс).

> **Виконано 06.08 ВЖЕ НА МАКУ (не на Windows).** Оскільки сервер був готовий раніше,
> ніж дійшли руки до prework, Task 0 зроблено прямо на маку — тож усе, що план
> передбачав лише «написати, запустити пізніше», реально **зібрано і прогнано**:
> - `swift test` — **7/7 зелених** (TimelineAccountant + smoke), справжній TDD-цикл RED→GREEN;
> - `Tools/selftest_drift.py` — **4/4 кейсів** (0/150/400/−150 мс), точність вимірювача ±3 мс;
> - `xcodegen generate` — проєкт генерується, `project.yml` валідний.
>
> **Відхилення від букви плану (обґрунтоване):** тести написані на **swift-testing**,
> а не XCTest. Причина: XCTest постачається лише всередині Xcode, якого на стенді ще
> немає (потрібен Apple ID — блокер на людину), а swift-testing працює на чистих
> Command Line Tools. Це розблокувало TDD на добу раніше. Деталі — ENGINEERING_NOTES §7.
> Виконані частини Tasks 3/4/5/13 позначені чекбоксами як done-in-prework.

### Task 1: Оренда мака + доступи (HUMAN — Володимир, ~30 хв активних дій)

**Провайдер: flow.swiss — ВЕРИФІКОВАНО 06.08.** Trial: 14 днів або 20.00 CHF кредиту.
Mac Bare Metal: від CHF 0.27/год, мін. алокація 24 год (ліцензія Apple), погодинний
білінг без контракту; доступні M1 / M1-Max / M2-Pro; віддалений доступ — SSH + Screen
Sharing/VNC + веб-консоль. 20 CHF ≈ 3 доби M1 безкоштовно; перед вичерпанням кредиту —
Upgrade (додати оплату), інакше сервер зупиниться. Якщо Mac Bare Metal недоступний на
trial-акаунті — натиснути Upgrade і повторити. Запасні провайдери — `docs/notes/mac-providers.md`.

> **СЕРВЕР СТВОРЕНО 06.08** (Steps 2–3 виконані): macmini.m1.8-16-512
> (M1, 16 GB, 512 GB NVMe), **macOS Tahoe 26.5.2** (цільова версія ТЗ!), регіон ZRH1,
> виділений IP. Доступ: адміністративний користувач; відкриті лише порти 22 (SSH)
> і 5900 (VNC). Залишились Steps 4–8.

**Files:** нема (інфраструктура).

**Interfaces:**
- Produces: IP мака, SSH-логін, VNC-креденшели, пароль користувача macOS; працюючий `ssh <user>@<IP>`.

- [x] **Step 2:** https://my.flow.swiss → **Mac Bare Metal → Create** (або WIZARD → Mac Bare Metal): модель — найдешевший **Mac mini M1**; образ macOS — найновіший доступний (мін. 15; якщо є 26/Tahoe — брати його, це цільова версія ТЗ); локація — будь-яка швейцарська. Якщо просить Upgrade — виконати (оплата вже верифікована). Дочекатися статусу Ready (див. їхній Quickstart «Getting started with Mac Bare Metal»).
- [x] **Step 3:** У деталях сервера записати: **IP, ім'я користувача macOS, пароль** (flow.swiss показує креденшели адмін-користувача) і спосіб VNC-підключення. Якщо SSH не ввімкнений в образі — увімкнути через веб-консоль/Screen Sharing: System Settings → General → Sharing → Remote Login (SSH) = ON, Screen Sharing = ON.
- [x] **Step 4:** Перевірити з Windows: `ssh <user>@<IP>` → має відкритися zsh. Записати логін/IP — вони потрібні для Remote SSH сесії Remote SSH.
- [x] **Step 5:** Підключитися по VNC (RealVNC Viewer / TightVNC на `<IP>:5900`, креденшели macOS-користувача) → залогінитись у GUI-сесію macOS і **НЕ виходити з неї** (GUI-сесія має жити — інакше зникають аудіопристрої і TCC-діалоги).
- [x] **Step 6:** macOS: System Settings → General → Software Update → якщо мінор-апдейт доступний — поставити (мажорну міграцію не робити, час дорожчий).
- [x] **Step 7:** Дати Full Disk Access для sshd: System Settings → Privacy & Security → Full Disk Access → увімкнути `sshd-keygen-wrapper` (з'явиться після першого ssh-логіну; якщо нема — додати `/usr/libexec/sshd-keygen-wrapper` вручну).
- [x] **Step 8:** З Windows: Remote SSH → host `<IP>`, user `m1`, port 22. Відкрити цю сесію з цим планом (скопіювати `docs/` у репо на маку — Task 2 Step 5).

### Task 2: Bootstrap мака + репозиторій + CI skeleton

**Files:**
- Create: `~/dev/STLTH-Recorder-for-macOS/` (git repo), `.gitignore`, `README.md` (заглушка), `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: SSH-доступ із Task 1.
- Produces: репо `stlth-recorder` (локально + GitHub), встановлені brew/інструменти, зелений порожній CI.

- [x] **Step 1:** Встановити інструменти:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/opt/homebrew/bin/brew shellenv)"
brew install git gh xcodegen create-dmg python@3.12 xcodesorg/made/xcodes
brew install --cask blackhole-2ch zoom google-chrome
python3 -m pip install --user numpy soundfile
```

- [ ] **Step 2:** Встановити Xcode (потрібен Apple ID; це найдовший пасивний крок — запустити і не чекати біля екрана):

```bash
xcodes install --latest   # спитає Apple ID; альтернатива: App Store через VNC
sudo xcode-select -s /Applications/Xcode.app
xcodebuild -runFirstLaunch
```

Verify: `swift --version` → Swift 5.10+; `xcodebuild -version` → Xcode 16+.

- [x] **Step 3:** Створити репо:

```bash
mkdir -p ~/dev/STLTH-Recorder-for-macOS && cd ~/dev/STLTH-Recorder-for-macOS && git init -b main
printf '.DS_Store\n*.xcodeproj\nbuild/\nDerivedData/\n.build/\ndist/\n' > .gitignore
printf '# STLTH Recorder for macOS\n\nWIP. Див. docs/.\n' > README.md
git add -A && git commit -m "chore: repo skeleton"
gh auth login   # браузерний флоу через VNC, приватний скоуп repo
gh repo create stlth-recorder --private --source=. --push
```

- [x] **Step 4:** CI skeleton — `.github/workflows/ci.yml`:

```yaml
name: ci
on: [push]
jobs:
  test:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Unit tests (RecorderCore)
        run: |
          if [ -d RecorderCore ]; then swift test --package-path RecorderCore; else echo "no package yet"; fi
```

- [ ] **Step 5:** Скопіювати з Windows-теки проєкту в репо: `docs/design/{specs,plans}`, `docs/notes/` і **всі результати Task 0 (prework)**: `RecorderCore/`, `Tools/`, `project.yml`, `Makefile`, `ci.yml`, `README.md`, `docs/ENGINEERING_NOTES.md` (через сесію Remote SSH або `scp`). Одразу перевірити prework: `swift test --package-path RecorderCore` (перший запуск TimelineAccountant-тестів) і `make gen build`. Commit: `git add -A && git commit -m "docs+prework: spec, plan, skeletons" && git push`. Verify: Actions → зелений ран.

### Task 3: AudioCap — референс і перевірка TCC на цьому стенді (ВОРОТА-1)

**Files:**
- Create: `~/dev/reference/AudioCap` (клон, поза нашим репо), `docs/notes/audiocap-findings.md` у нашому репо

**Interfaces:**
- Produces: підтвердження, що system-audio tap ПРАЦЮЄ на цьому маку; конспект API-патернів (типи/виклики) для Task 6.

- [x] **Step 1:** `mkdir -p ~/dev/reference && cd ~/dev/reference && git clone https://github.com/insidegui/AudioCap.git`
- [x] **Step 2:** Зібрати і запустити через VNC: `open AudioCap/AudioCap.xcodeproj` → Run. Дозволити TCC-запит system audio. Запустити в Zoom тестовий мітинг (приєднатися з Windows як другий учасник, говорити) → записати хвилину звуку → переконатися, що файл містить голос.
- [x] **Step 3:** Законспектувати в `docs/notes/audiocap-findings.md`: точні виклики створення tap (`CATapDescription`, `AudioHardwareCreateProcessTap`), aggregate device (`AudioHardwareCreateAggregateDevice`, ключі sub-device/tap list), формат IO-колбека, як читається дозвіл TCC. Ці імена — джерело істини для Task 6 (код у Task 6 — орієнтир, AudioCap — істина).
- [x] **Step 4:** Commit + push. **GATE: якщо tap не працює на хмарному маку — СТОП, ескалація людині (план Б: терміновий пошук фізичного мака). Далі не йти.**

### Task 4: Skeleton проєкту: XcodeGen + RecorderCore + порожній menu bar app

**Files:**
- Create: `project.yml`, `App/Sources/STLTHRecorderApp.swift`, `App/Info.plist`, `App/STLTHRecorder.entitlements`, `RecorderCore/Package.swift`, `RecorderCore/Sources/RecorderCore/RecorderCore.swift`, `RecorderCore/Tests/RecorderCoreTests/SmokeTests.swift`

**Interfaces:**
- Produces: `make build` збирає `.app`; SPM-пакет `RecorderCore` з тестами; app показує іконку в menu bar.

- [x] **Step 1:** `RecorderCore/Package.swift`:

```swift
// swift-tools-version:5.10
import PackageDescription
let package = Package(
    name: "RecorderCore",
    platforms: [.macOS("14.4")],
    products: [.library(name: "RecorderCore", targets: ["RecorderCore"])],
    targets: [
        .target(name: "RecorderCore"),
        .testTarget(name: "RecorderCoreTests", dependencies: ["RecorderCore"]),
    ]
)
```

`RecorderCore.swift`: `public enum RecorderCore { public static let version = "0.1.0" }`
`SmokeTests.swift`: тест, що `RecorderCore.version == "0.1.0"`.

- [x] **Step 2:** `swift test --package-path RecorderCore` → PASS. Commit `feat: RecorderCore package`.
- [x] **Step 3:** `project.yml`:

```yaml
name: STLTHRecorder
options: { bundleIdPrefix: ua.stlth, deploymentTarget: { macOS: "14.4" } }
packages: { RecorderCore: { path: RecorderCore } }
targets:
  STLTHRecorder:
    type: application
    platform: macOS
    sources: [App/Sources]
    dependencies: [{ package: RecorderCore }]
    info:
      path: App/Info.plist
      properties:
        LSUIElement: true
        CFBundleDisplayName: STLTH Recorder for macOS
        NSMicrophoneUsageDescription: "STLTH Recorder for macOS записує ваш голос під час зустрічі."
        NSAudioCaptureUsageDescription: "STLTH Recorder for macOS записує звук зустрічі (голос клієнта)."
    entitlements:
      path: App/STLTHRecorder.entitlements
      properties:
        com.apple.security.device.audio-input: true
```

(Точний ключ usage-опису для system audio звірити з AudioCap — Task 3 конспект.)

- [x] **Step 4:** `App/Sources/STLTHRecorderApp.swift` — мінімальний menu bar:

```swift
import SwiftUI
@main
struct STLTHRecorderApp: App {
    var body: some Scene {
        MenuBarExtra("STLTH Recorder for macOS", systemImage: "record.circle") {
            Text("STLTH Recorder for macOS — скелет")
            Divider()
            Button("Вийти") { NSApplication.shared.terminate(nil) }
        }
    }
}
```

- [ ] **Step 5:** `Makefile`-цілі: `gen` (xcodegen), `build` (`xcodebuild -scheme STLTHRecorder -configuration Release -derivedDataPath build build`), `run` (open збілджений .app), `test` (swift test). `make gen build run` → іконка в menu bar через VNC. Commit `feat: app skeleton (menu bar)`.

### Task 5: TimelineAccountant — інваріант таймлайна (чистий TDD)

**Files:**
- Create: `RecorderCore/Sources/RecorderCore/TimelineAccountant.swift`, `RecorderCore/Tests/RecorderCoreTests/TimelineAccountantTests.swift`

**Interfaces:**
- Produces: `struct TimelineAccountant { init(sampleRate: Double); mutating func frames(toInsertBefore bufferTimestamp: Double, frameCount: Int) -> Int; var totalFrames: Int }` — рахує, скільки семплів тиші вставити перед буфером, якщо між буферами був розрив (за host-time), і веде лічильник записаного.

- [x] **Step 1:** Failing tests:

```swift
import XCTest
@testable import RecorderCore
final class TimelineAccountantTests: XCTestCase {
    func testContiguousBuffersNeedNoPadding() {
        var acc = TimelineAccountant(sampleRate: 48000)
        XCTAssertEqual(acc.frames(toInsertBefore: 0.0, frameCount: 480), 0)
        XCTAssertEqual(acc.frames(toInsertBefore: 0.01, frameCount: 480), 0) // рівно наступний буфер
        XCTAssertEqual(acc.totalFrames, 960)
    }
    func testGapIsPaddedWithSilence() {
        var acc = TimelineAccountant(sampleRate: 48000)
        _ = acc.frames(toInsertBefore: 0.0, frameCount: 480)
        // розрив 2.01 c від кінця попереднього буфера (0.01) => 2.0 c тиші = 96000 семплів
        XCTAssertEqual(acc.frames(toInsertBefore: 2.01, frameCount: 480), 96000)
        XCTAssertEqual(acc.totalFrames, 480 + 96000 + 480)
    }
    func testJitterBelowThresholdIgnored() {
        var acc = TimelineAccountant(sampleRate: 48000)
        _ = acc.frames(toInsertBefore: 0.0, frameCount: 480)
        XCTAssertEqual(acc.frames(toInsertBefore: 0.0105, frameCount: 480), 0) // 0.5 мс джитер — не розрив
    }
}
```

- [x] **Step 2:** Run → FAIL (тип не існує).
- [x] **Step 3:** Імплементація:

```swift
public struct TimelineAccountant {
    public private(set) var totalFrames: Int = 0
    private let sampleRate: Double
    private var expectedNext: Double? = nil
    private let jitterTolerance = 0.005 // 5 мс
    public init(sampleRate: Double) { self.sampleRate = sampleRate }
    public mutating func frames(toInsertBefore ts: Double, frameCount: Int) -> Int {
        var pad = 0
        if let exp = expectedNext, ts - exp > jitterTolerance {
            pad = Int(((ts - exp) * sampleRate).rounded())
        }
        expectedNext = ts + Double(frameCount) / sampleRate
        totalFrames += pad + frameCount
        return pad
    }
}
```

- [x] **Step 4:** Run → PASS. **Step 5:** Commit `feat: timeline accountant (silence padding invariant)`.

### Task 6: AudioEngine — спайк захоплення (ВОРОТА-2, серце проєкту)

**Files:**
- Create: `RecorderCore/Sources/RecorderCore/AudioEngine.swift`, `RecorderCore/Sources/RecorderCore/CAFWriter.swift`, `Tools/recorder-cli/main.swift` (CLI-стенд), доповнити `project.yml` таргетом `recorder-cli`

**Interfaces:**
- Consumes: конспект AudioCap (Task 3), `TimelineAccountant` (Task 5).
- Produces: `final class AudioEngine { init(sessionDir: URL) throws; func start() throws; func stop() -> RecordingResult }`, де `struct RecordingResult { let micURL: URL; let systemURL: URL; let durationMs: Int; let inputDeviceName: String; let outputDeviceName: String }`. Пише `mic.caf` (mono) і `system.caf` (stereo) потоково.

**УВАГА виконавцю:** код нижче — структурний орієнтир. Точні CoreAudio-виклики бери з клонованого AudioCap (`~/dev/reference/AudioCap`) — він компілюється і працює (доведено воротами-1). Кожні ~20 рядків — компілюй (`make build`). Не вигадуй імена API з пам'яті.

- [x] **Step 1:** `CAFWriter.swift` — обгортка AVAudioFile: `init(url: URL, channels: AVAudioChannelCount) throws` (LPCM 16-bit, 48 кГц, CAF), `func write(_ buffer: AVAudioPCMBuffer) throws`, `func writeSilence(frames: Int) throws`. Юніт-тест: створити writer, записати 480 семплів синуса + 480 тиші, перевідкрити файл через AVAudioFile → `length == 960`.
- [x] **Step 2:** Run test → PASS. Commit `feat: CAF writer`.
- [x] **Step 3:** `AudioEngine.swift` — за патернами AudioCap: (1) створити global tap: `CATapDescription` (mixdown усіх процесів, `excludeCurrentProcess`), `AudioHardwareCreateProcessTap`; (2) створити aggregate device: default input device + tap (ключі — з AudioCap); (3) `AudioDeviceCreateIOProcIDWithBlock` на aggregate: у колбеку розкласти вхідні буфери на mic-канали і tap-канали, кожен → свій `TimelineAccountant` → `writeSilence(pad)` + `write(buffer)`; (4) `stop()`: зупинити IO, знищити aggregate і tap, повернути `RecordingResult` (тривалість — з `totalFrames / 48000`; імена пристроїв — через `kAudioObjectPropertyName` дефолтних input/output).
- [x] **Step 4:** CLI-стенд `recorder-cli`: `record <секунд>` → створює `/tmp/rec-<ts>/`, запускає AudioEngine, чекає, стоп, друкує шляхи і тривалість.
- [x] **Step 5 (інтеграційний тест на стенді):** грати музику в браузері + Zoom-мітинг з Windows-«клієнтом»; `./recorder-cli record 30`; перевірити: обидва файли відкриваються QuickTime, у `system.caf` чутно звук, у `mic.caf` — тиша (мікрофона нема) або BlackHole-сигнал, `length == 30 * 48000 ± 1 буфер` в обох.
- [x] **Step 6:** Commit `feat: audio engine (global tap + aggregate device)`. **GATE-2 пройдено.**

### Task 7: SessionStore + meta.json (TDD)

**Files:**
- Create: `RecorderCore/Sources/RecorderCore/SessionStore.swift`, `RecorderCore/Sources/RecorderCore/SessionMeta.swift`, `RecorderCore/Tests/RecorderCoreTests/SessionStoreTests.swift`

**Interfaces:**
- Consumes: `RecordingResult` (Task 6).
- Produces:
  - `struct SessionMeta: Codable` — поля точно за спекою §2 (sessionId, startedAt ISO8601+TZ, durationMs, status: "recording"|"completed"|"interrupted", consent{confirmed,at}, tracks[{channel,speaker,file,format,sampleRate,channels}], devices{input,output}, deviceChanges[], appVersion, osVersion).
  - `final class SessionStore { init(root: URL); func begin(consentAt: Date) throws -> SessionHandle; func complete(_ h: SessionHandle, result: RecordingResult) throws; func recoverInterrupted(); func list() -> [SessionMeta]; func delete(id: UUID) throws }`; `struct SessionHandle { let id: UUID; let dir: URL }`.

- [x] **Step 1:** Failing tests (root = тимчасова тека): (a) `begin` створює теку і `meta.json` зі status="recording" і consent; (b) `complete` дописує durationMs/tracks/devices і status="completed"; (c) round-trip `SessionMeta` через JSONEncoder/Decoder зі стратегією ISO8601; (d) `recoverInterrupted` знаходить сесію зі status="recording", міряє довжину caf-файлів (створити фікстуру через CAFWriter) і ставить status="interrupted" з коректним durationMs; (e) `list` сортує за startedAt desc; (f) `delete` прибирає теку.
- [x] **Step 2:** Run → FAIL. **Step 3:** Імплементація (root за замовчуванням `~/Library/Application Support/STLTHRecorder/Sessions/`; meta пишеться атомарно: tmp-файл + rename). **Step 4:** Run → PASS. **Step 5:** Commit `feat: session store + meta.json`.

### Task 8: RecorderController — state machine (TDD)

**Files:**
- Create: `RecorderCore/Sources/RecorderCore/RecorderController.swift`, `RecorderCore/Tests/RecorderCoreTests/RecorderControllerTests.swift`

**Interfaces:**
- Consumes: `SessionStore`, `AudioEngine` (через протокол `AudioEngineProtocol { func start() throws; func stop() -> RecordingResult }` — для тестів мок).
- Produces: `@MainActor final class RecorderController: ObservableObject { enum State: Equatable { case idle, preparing, recording(started: Date), stopping }; @Published var state: State; func startTapped(consentAt: Date); func stopTapped(); var elapsed: TimeInterval }`.

- [x] **Step 1:** Failing tests з мок-engine: (a) start з idle → recording, створена сесія; (b) start у recording — ігнорується, друга сесія НЕ створюється (вимога ТЗ про дубль); (c) stop → idle, сесія completed; (d) помилка engine.start (мок кидає) → state=idle, сесія позначена interrupted, помилка доступна UI.
- [x] **Step 2:** FAIL → **Step 3:** імплементація → **Step 4:** PASS → **Step 5:** Commit `feat: recorder state machine`.

### Task 9: Menu bar UI (старт/стоп/статус/тривалість/згода)

**Files:**
- Create: `App/Sources/MenuBarView.swift`, `App/Sources/ConsentSheet.swift`; Modify: `App/Sources/STLTHRecorderApp.swift`

**Interfaces:**
- Consumes: `RecorderController` (Task 8), `PermissionsService` (Task 10 — до того кнопка дозволів прихована за `#if`).
- Produces: робочий UI українською.

- [x] **Step 1:** `MenuBarExtra` з динамічною іконкою: idle → `record.circle`, recording → `record.circle.fill` (червона, `.symbolRenderingMode(.multicolor)`) + **тривалість прямо в menu bar** (`MenuBarExtra` label = іконка+`Text(elapsed, format:...)`) — «не можна не помітити» з ТЗ.
- [x] **Step 2:** Меню: `Почати запис` / `Зупинити запис (ЧЧ:ХХ:СС)`, `Останні записи ▸` (заглушка до Task 11), `Налаштування…`, `Вийти`. Клік «Почати» → `ConsentSheet` (вікно поверх): текст «Підтвердіть, що клієнт дав згоду на запис зустрічі», кнопки `Підтверджую — почати запис` / `Скасувати`; підтвердження → `controller.startTapped(consentAt: .now)`.
- [ ] **Step 3:** Ручний тест через VNC: старт → таймер тікає в menu bar; повторний «старт» недоступний; стоп → сесія в `~/Library/Application Support/STLTHRecorder/Sessions/`, meta валідний (`python3 -m json.tool meta.json`).
- [ ] **Step 4:** Commit `feat: menu bar UI + consent flow (uk)`.

### Task 10: PermissionsService + індикація дозволів

**Files:**
- Create: `RecorderCore/Sources/RecorderCore/PermissionsService.swift`, `App/Sources/PermissionsView.swift`

**Interfaces:**
- Produces: `final class PermissionsService: ObservableObject { enum Status { case granted, denied, undetermined }; @Published var microphone: Status; @Published var systemAudio: Status; func refresh(); func requestMicrophone() async; func openSystemSettings(for: Kind) }`. Мікрофон — `AVCaptureDevice.authorizationStatus(for: .audio)`; system audio — патерн з AudioCap (Task 3 конспект); deep links: `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` та відповідний для Audio Recording (звірити з AudioCap).

- [x] **Step 1:** Секція меню «Дозволи»: два рядки з ● зелений/`granted`, ● червоний/`denied` + при denied кнопка `Відкрити налаштування…` і підказка «Увімкніть STLTH Recorder for macOS у списку та перезапустіть застосунок».
- [x] **Step 2:** `RecorderController.startTapped` перед стартом викликає `refresh()`; якщо не granted — не стартує, показує PermissionsView (вимога ТЗ: зрозуміла підказка відновлення).
- [ ] **Step 3:** Ручний тест: відкликати мікрофон у System Settings → у меню червоний індикатор + кнопка веде в правильну панель; повернути дозвіл → зелений після refresh.
- [ ] **Step 4:** Commit `feat: permissions service + UI`.

### Task 11: Останні записи: список, Finder, видалення, налаштування

**Files:**
- Create: `App/Sources/RecentSessionsView.swift`, `App/Sources/SettingsView.swift`; Modify: `App/Sources/MenuBarView.swift`

**Interfaces:**
- Consumes: `SessionStore.list()/delete(id:)` (Task 7).
- Produces: підменю «Останні записи» (5 останніх: дата+тривалість) → клік = `NSWorkspace.shared.activateFileViewerSelecting([dir])`; контекст/кнопка «Видалити запис» з підтвердженням (`NSAlert`, укр.). Settings: toggle «Запускати при вході в систему» → `SMAppService.mainApp.register()/unregister()`.

- [x] **Step 1:** Імплементація + ручний тест: записати 2 сесії → обидві в списку, Finder відкривається на теці, видалення прибирає теку і рядок.
- [ ] **Step 2:** Перевірити автозапуск: увімкнути toggle → `sudo reboot` мака → після перезавантаження (заново зайти VNC) іконка є в menu bar. (Це ж критерій приймання №5 частково.)
- [ ] **Step 3:** Commit `feat: recent sessions + settings (launch at login)`.

### Task 12: Edge cases: зміна пристрою, watchdog, диск, відновлення

**Files:**
- Create: `RecorderCore/Sources/RecorderCore/DeviceMonitor.swift`, `RecorderCore/Sources/RecorderCore/DiskGuard.swift`; Modify: `AudioEngine.swift`, `RecorderController.swift`

**Interfaces:**
- Produces: `DeviceMonitor { var onDefaultDeviceChanged: (String) -> Void }` (listener на `kAudioHardwarePropertyDefaultInputDevice/OutputDevice`); `DiskGuard { static func freeBytes(at: URL) -> Int64 }`; retry-логіка в AudioEngine.

- [x] **Step 1 (TDD де можливо):** юніт-тести: DiskGuard повертає > 0 для тимчасової теки; SessionMeta коректно серіалізує `deviceChanges` append.
- [x] **Step 2:** Зміна дефолтного пристрою під час запису → AudioEngine перебудовує aggregate (stop IO → rebuild → start IO), `TimelineAccountant` кладе тишу на розрив, подія в `deviceChanges`. Реалізовано (`buildCaptureGraph` + `rebuildCaptureGraph`, коміт `d145063`), юніт-тест на потрапляння подій у `meta.json` зелений. Апаратний прогін пройдено (`Tools/device-change-test.sh`, 08.08): два перемикання виходу під час 30-секундного запису — обидва в `meta.json`, звук присутній у всіх трьох відрізках (peak 0.80), треки 1 444 253 семпли обидва. Прогін виявив баг: слухач висів на `DispatchQueue.main`, тож у headless-режимі не спрацьовував жодного разу — виправлено (коміт `ae35a34`).
- [x] **Step 3 (ПЕРЕГЛЯНУТО і реалізовано):** початкове формулювання «немає колбеків > 3 с → rebuild» було хибним: process tap не віддає колбеків, поки жоден процес нічого не грає, тож будь-яка зустріч, що починається з тиші, отримувала б перезапуск. Проба `Tools/running-probe` (08.08) дала точну поведінку: до першого звуку `DeviceIsRunning=false` і 0 колбеків; після старту потік іде безперервно — 94 колбеки/с крізь 40 с тиші. Тому критерієм став збіг двох умов: потік уже стартував **і** пристрій звітує `DeviceIsRunning=true`, а колбеків немає > 3 с. Правило винесене в чисту функцію `AudioEngine.shouldRebuild` і покрите 6 тестами; на залізі хибних спрацювань немає.
- [x] **Step 4:** DiskGuard: при старті < 1 ГБ → попередження в ConsentSheet; під час запису < 200 МБ → авто-стоп з `NSAlert` «Запис зупинено: закінчується місце на диску».
- [x] **Step 5:** Відновлення: `recoverInterrupted()` викликається при старті застосунку (вже реалізовано в Task 7) — інтеграційний тест пройдено (`Tools/crash-recovery-test.sh`, 08.08): `kill -9` на 15-й секунді → статус `interrupted`, тривалість 14.680 с, обидва треки 704 655 семплів і читаються libsndfile (тобто `CAFRepair` спрацював). Опис тесту: почати запис, `kill -9` процеса, перезапустити → сесія в списку зі статусом «перервана», аудіо читається.
- [ ] **Step 6:** Commit `feat: device change, watchdog, disk guard, crash recovery`.

### Task 13: drift-check + інтеграційний стенд + soak

**Files:**
- Create: `Tools/drift_check.py`, `Tools/gen_clicks.py`, `docs/notes/drift-report.md`, `Tools/soak.sh`

**Interfaces:**
- Consumes: `recorder-cli` (Task 6), BlackHole (стенд).
- Produces: числовий звіт розсинхрону; нічний soak-протокол.

- [x] **Step 1:** `gen_clicks.py`: WAV 60 c, клік (1 кГц, 10 мс) кожні 5 с. `drift_check.py`: читає `mic.caf` і `system.caf` (`soundfile`), знаходить піки кліків у кожному, друкує offset на початку, в кінці, максимум; exit 1 якщо max > 0.3 c.
- [x] **Step 2:** Стенд: default output → Multi-Output (динамік + BlackHole); default input → BlackHole; грати кліки (`afplay clicks.wav`) під час `recorder-cli record 70` → кліки в ОБОХ каналах (system — бо грає системою, mic — бо BlackHole loopback). `python3 drift_check.py <dir>` → звіт у `docs/notes/drift-report.md` (число!).
- [ ] **Step 3:** `soak.sh`: `recorder-cli record 7200` + YouTube-відео в Chrome на автоплеї; запустити на ніч (`caffeinate -s`). Вранці: файли цілі, тривалість точна, пам'ять процеса стабільна (знімати `footprint` до/після).
- [ ] **Step 4:** Zoom/Meet приймальні прогони: 60-хв Zoom (Володимир з Windows — «клієнт») і Meet у Chrome; після кожного — drift_check + прослухати вибірково. Результати → приймальна матриця (Task 14).
- [ ] **Step 5:** Commit `test: drift harness + soak + acceptance runs`.

### Task 14: Дистрибуція: DMG, ad-hoc підпис, README, ENGINEERING_NOTES

**Files:**
- Create: `scripts/release.sh`, `README.md` (повний), `docs/ENGINEERING_NOTES.md`

**Interfaces:**
- Consumes: усе попереднє.
- Produces: `dist/STLTHRecorder-1.0.0.dmg` у GitHub Releases; повна документація укр.

- [x] **Step 1:** `scripts/release.sh`: `make gen build` (Release) → `codesign --force --deep -s - build/.../STLTHRecorder.app` (ad-hoc) → `create-dmg` → `dist/`. Verify: DMG монтується, app запускається після right-click → Open.
- [ ] **Step 2:** «Чиста машина»: створити нового користувача macOS (`sysadminctl -addAccount`) або переустановити ОС через Scaleway console (якщо час дозволяє — друге чесніше) → поставити з DMG → пройти всі 6 критеріїв ТЗ → зафіксувати результати.
- [ ] **Step 3:** `README.md` (укр.): що це, скріншоти, встановлення (з інструкцією Gatekeeper right-click → Open, бо ad-hoc підпис), перші кроки/дозволи, **приймальна матриця**: критерій ТЗ №1–6 → кроки → результат → дата.
- [ ] **Step 4:** `docs/ENGINEERING_NOTES.md`: розвилки і рішення (global tap vs per-process vs ScreenCaptureKit; синхронність через aggregate device; інваріант таймлайна; знахідки з AudioCap/Hyprnote/Meetily; обмеження хмарного стенда; що б робив далі). Це інженерна розповідь — писати з посиланнями на код.
- [ ] **Step 5:** `gh release create v1.0.0 dist/*.dmg --title "STLTH Recorder for macOS 1.0.0"` + фінальний пуш. Commit `docs: README + engineering notes; release 1.0.0`.

### Task 15 (P5): Онбординг + «Перевірити оновлення»

**Files:**
- Create: `App/Sources/OnboardingWindow.swift`; Modify: `MenuBarView.swift`, `STLTHRecorderApp.swift`

- [ ] **Step 1:** OnboardingWindow при першому запуску (`@AppStorage("didOnboard")`): 3 кроки — «Що це» → «Дозвіл мікрофона» (кнопка запиту) → «Дозвіл системного аудіо» (кнопка запиту + пояснення, чому це безпечно: звук лишається на цьому Mac). Пропуск можливий; повторний вхід — з меню «Довідка».
- [ ] **Step 2:** Пункт меню «Перевірити оновлення…» → `NSWorkspace.shared.open(URL(string:"https://github.com/<user>/STLTH-Recorder-for-macOS/releases/latest")!)`. Без Sparkle (рішення спеки).
- [ ] **Step 3:** Ручний тест нового користувача macOS → онбординг веде до працюючого запису без підказок ззовні. Commit `feat: onboarding + check updates`.

### Task 16 (P5): Локальна транскрибація (whisper.cpp)

**Files:**
- Create: `TranscriptionKit/Package.swift`, `TranscriptionKit/Sources/TranscriptionKit/Transcriber.swift`; Modify: `RecentSessionsView.swift`, `SessionMeta.swift` (поле `transcripts`)

**Interfaces:**
- Produces: `final class Transcriber { init(modelURL: URL); func transcribe(fileURL: URL, language: String) async throws -> String }` поверх whisper.cpp (SPM-залежність `https://github.com/ggerganov/whisper.cpp`, target XCFramework); модель `ggml-base-q5_1` (мультимовна, ~60 МБ) — завантажується при першому використанні у `~/Library/Application Support/STLTHRecorder/Models/` з прогрес-баром і явною згодою (єдиний мережевий запит, тільки за кліком).

- [ ] **Step 1:** У «Останні записи» → пункт «Транскрибувати» на сесії: конвертація CAF → 16 кГц mono WAV (`AVAudioConverter`) → транскрипція mic і system окремо → `transcript.md` у теці сесії: дві секції «Радник» / «Клієнт» з таймстемпами сегментів.
- [ ] **Step 2:** Тест на реальній сесії укр. мовою; перевірити якість base-моделі; якщо слабко — спробувати `small-q5_1` (~200 МБ), зафіксувати вибір у ENGINEERING_NOTES.
- [ ] **Step 3:** Commit `feat: local transcription (whisper.cpp, uk)`. У README — секція «Наступний крок платформи» з цим бонусом.

---

## Self-review notes

- Покриття спеки: §1→T3/T6; §2→T4/T7; §3→T8/T9; §4→T10/T12; §5→T5/T13/T14; §6 roadmap→порядок задач; §7→T14; P5→T15/T16. Автозапуск (ТЗ A)→T11; згода→T9; дозволи→T10; критерії №1–6→T13/T14.
- Типи звірені: `RecordingResult` (T6) споживається T7/T8; `SessionHandle/SessionMeta` (T7) — T8/T11/T16; `AudioEngineProtocol` (T8) — мок тестів.
- CoreAudio-код свідомо задано патернами з посиланням на AudioCap як джерело істини (ворота T3) — це рішення проти галюцинацій API, не плейсхолдер.
