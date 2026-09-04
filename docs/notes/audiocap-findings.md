# AudioCap: конспект CoreAudio process-tap API

> ## ✅ GATE-1 і GATE-2 ПРОЙДЕНО 07.08
>
> Після видачі TCC-дозволу (`kTCCServiceAudioCapture` → `com.apple.Terminal`, auth=2):
>
> | Перевірка | Результат |
> |---|---|
> | Спайк `tapprobe` | 747 колбеків, **peak 0.694 / RMS 0.412** — реальний звук |
> | Наш `AudioEngine` через `recorder-cli` | 937 колбеків за 10 с |
> | `system.caf` | 2 канали, 479 744 фрейми, **peak 0.694 / RMS 0.411** |
> | `mic.caf` | 1 канал, **479 744 фрейми** (тиша — мікрофона на стенді немає) |
> | Інваріант таймлайна | обидва треки **однакової довжини**, Δ до очікуваного = 16 семплів (0.3 мс) |
> | `meta.json` | валідний, повний, ISO8601 зі зсувом |
>
> Докази: `docs/notes/evidence/`. Архітектура «global tap + aggregate device»
> **підтверджена на залізі** — гіпотези 🔬 нижче знято, крім мікрофонної частини.
>
> **Важливо для стенда:** TCC-дозвіл прив'язаний до процесу-власника. Запуск зі
> **SSH дає колбеки з нулями** (успадковується оточення sshd, не Terminal) — тестові
> прогони треба робити з Terminal у GUI-сесії. Для продукту це неважливо: `.app`
> отримає власний запис TCC.

> **Статус перевірки:** конспект складено з **реального коду** AudioCap
> (`~/dev/reference/AudioCap`, клон `insidegui/AudioCap`) і **SDK-хедерів**
> `CoreAudio.framework` на цьому маку (macOS 26.6, Command Line Tools SDK).
> **НЕ перевірено на залізі** — GATE-1 (Task 3 Step 2: реальний захват звуку)
> лишається обов'язковим. Усе, що нижче позначено 🔬, — гіпотеза, яку валідує GATE-1.

**Джерела істини:**
- Код: `AudioCap/ProcessTap/ProcessTap.swift`, `AudioRecordingPermission.swift`, `CoreAudioUtils.swift`
- Хедери: `$(xcrun --show-sdk-path)/System/Library/Frameworks/CoreAudio.framework/Versions/A/Headers/`
  → `CATapDescription.h`, `AudioHardwareTapping.h`, `AudioHardware.h`

---

## 0. Головне відкриття для нашого стенда

Tap-API живуть у **CoreAudio.framework**, а не в AudioToolbox, і **присутні в SDK
Command Line Tools**. Отже CoreAudio-код компілюється `swiftc`/SPM **без повного Xcode**.
Xcode потрібен лише для `.xcodeproj`-збірки самого AudioCap і для `xcodebuild` нашого
`.app` (Task 4). Спайк ядра можна робити CLI-таргетом раніше.

Обидва tap-хедери — `#ifdef __OBJC__`, тобто доступні Swift/ObjC, не чистому C++.

---

## 1. Дозвіл (TCC)

| Що | Значення |
|---|---|
| Ключ Info.plist | **`NSAudioCaptureUsageDescription`** (у дропдауні Xcode його нема — вписувати вручну) |
| TCC-сервіс | `kTCCServiceAudioCapture` |
| Публічного API перевірки/запиту | **немає** |

Без приватного API дозвіл питається **автоматично при першій спробі запису**. AudioCap
додатково читає стан через приватний TCC SPI під прапорцем збірки `-D ENABLE_TCC_SPI`
(`Config/Main.xcconfig`), через `dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC")`
+ `dlsym`:

```swift
// приватний SPI — лише для читання/запиту статусу
typealias PreflightFuncType = @convention(c) (CFString, CFDictionary?) -> Int
typealias RequestFuncType   = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void
// TCCAccessPreflight("kTCCServiceAudioCapture", nil) -> 0 = authorized, 1 = denied, інше = unknown
// TCCAccessRequest("kTCCServiceAudioCapture", nil) { granted in ... }
```

**Рішення для STLTH Recorder for macOS (Task 10):** приватний SPI у продукт **не тягнемо** —
це ризик на ревʼю і при апдейтах ОС. Статус system-audio виводимо непрямо: спроба
створити tap + перший IO-колбек. Мікрофон читається публічно
(`AVCaptureDevice.authorizationStatus(for: .audio)`). 🔬 Якщо на GATE-1 виявиться, що
без SPI стан невідрізнимий для UI — повернутись до цього рішення разом із користувачем.

**Entitlements AudioCap:** `com.apple.security.app-sandbox`,
`com.apple.security.device.audio-input`, `com.apple.security.files.user-selected.read-write`.
Окремого entitlement для system-audio **немає** — усе вирішує TCC + usage-ключ.

---

## 2. Створення tap

### 2.1 Per-process (як робить AudioCap)

```swift
let tapDescription = CATapDescription(stereoMixdownOfProcesses: [objectID])
tapDescription.uuid = UUID()
tapDescription.muteBehavior = .unmuted        // або .mutedWhenTapped
var tapID: AUAudioObjectID = .unknown
let err = AudioHardwareCreateProcessTap(tapDescription, &tapID)
```

PID → `AudioObjectID` процесу: `kAudioHardwarePropertyTranslatePIDToProcessObject`
(qualifier = `pid_t`). Список аудіопроцесів: `kAudioHardwarePropertyProcessObjectList`.

### 2.2 Global tap — **наш шлях** (звірено з `CATapDescription.h`)

```objc
- (instancetype) initStereoGlobalTapButExcludeProcesses:(NSArray<NSNumber*>*)processesObjectIDsToExcludeFromTap
```

У Swift (`NS_REFINED_FOR_SWIFT`) це:

```swift
let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [ourOwnProcessObjectID])
tapDescription.uuid = UUID()
tapDescription.name = "STLTHRecorderSystemTap"
tapDescription.isPrivate = true          // властивість privateTap, getter isPrivate
tapDescription.muteBehavior = .unmuted   // ОБОВ'ЯЗКОВО unmuted: співрозмовника має чути користувач
```

Порожній масив = тап усього без винятків. Ми виключаємо **власний процес**
(вимога спеки §1) — інакше ризик петлі, якщо застосунок колись відтворюватиме звук.
`ourOwnProcessObjectID` отримуємо через `translatePIDToProcessObjectID(pid: getpid())`.

Інші доступні варіанти: `initMonoGlobalTapButExcludeProcesses`,
`initExcludingProcesses:andDeviceUID:withStream:` (тап конкретного стріму пристрою).
Ми беремо **stereo global** — `system.caf` за спекою стерео.

**Знищення:** `AudioHardwareDestroyProcessTap(tapID)`.

**Формат tap:** читається як властивість `kAudioTapPropertyFormat` (`'tfmt'`) з `tapID`
→ `AudioStreamBasicDescription`. Читати **після** створення tap і **до** створення
aggregate. У AudioCap це `readAudioTapStreamBasicDescription()`.

Доступні також `kAudioTapPropertyUID` (`'tuid'`), `kAudioTapPropertyDescription` (`'tdsc'`).

---

## 3. Aggregate device

Ключі словника — точні значення з `AudioHardware.h` (рядки 1566–1900):

| Константа | Рядок |
|---|---|
| `kAudioAggregateDeviceUIDKey` | `"uid"` |
| `kAudioAggregateDeviceNameKey` | `"name"` |
| `kAudioAggregateDeviceSubDeviceListKey` | `"subdevices"` |
| `kAudioAggregateDeviceMainSubDeviceKey` | `"master"` |
| `kAudioAggregateDeviceClockDeviceKey` | `"clock"` |
| `kAudioAggregateDeviceIsPrivateKey` | `"private"` |
| `kAudioAggregateDeviceIsStackedKey` | `"stacked"` |
| `kAudioAggregateDeviceTapListKey` | `"taps"` |
| `kAudioAggregateDeviceTapAutoStartKey` | `"tapautostart"` |
| `kAudioSubDeviceUIDKey` | `"uid"` |
| `kAudioSubDeviceDriftCompensationKey` | `"drift"` |
| `kAudioSubTapUIDKey` | `"uid"` |
| `kAudioSubTapDriftCompensationKey` | `"drift"` |

### 3.1 Як робить AudioCap (tap + вихідний пристрій)

```swift
let outputUID = try AudioDeviceID.readDefaultSystemOutputDevice().readDeviceUID()
let description: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Tap-\(process.id)",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceMainSubDeviceKey: outputUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
    kAudioAggregateDeviceTapListKey: [[
        kAudioSubTapDriftCompensationKey: true,
        kAudioSubTapUIDKey: tapDescription.uuid.uuidString,   // UUID ОПИСУ, не tapID!
    ]],
]
var aggregateDeviceID = AudioObjectID.unknown
AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)
```

⚠️ **Пастка:** у `kAudioSubTapUIDKey` кладеться `tapDescription.uuid.uuidString`
(UUID **опису**), а не числовий `AudioObjectID` tap. Саме тому `uuid` виставляють
явно до створення tap.

### 3.2 Наш варіант: **мікрофон + tap в одному aggregate** 🔬

Ключова відмінність від AudioCap і суть архітектури (спека §1): у `subdevices`
додається **default input device** (мікрофон), тож один IO-проц віддає обидва тракти
з одного годинника → синхронність за побудовою.

```swift
let inputUID  = try defaultInputDeviceID.readDeviceUID()
let outputUID = try AudioDeviceID.readDefaultSystemOutputDevice().readDeviceUID()
let description: [String: Any] = [
    kAudioAggregateDeviceNameKey: "STLTHRecorderAggregate",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceMainSubDeviceKey: outputUID,          // 🔬 див. відкриті питання
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [
        [kAudioSubDeviceUIDKey: outputUID],
        [kAudioSubDeviceUIDKey: inputUID, kAudioSubDeviceDriftCompensationKey: true],
    ],
    kAudioAggregateDeviceTapListKey: [[
        kAudioSubTapDriftCompensationKey: true,
        kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
    ]],
]
```

**Знищення:** `AudioHardwareDestroyAggregateDevice(aggregateDeviceID)` — **після**
`AudioDeviceStop` і `AudioDeviceDestroyIOProcID`, і **до** `AudioHardwareDestroyProcessTap`
(порядок узятий з `ProcessTap.invalidate()`).

---

## 4. IO-проц і запис

```swift
let queue = DispatchQueue(label: "STLTHRecorderIO", qos: .userInitiated)
var deviceProcID: AudioDeviceIOProcID?
AudioDeviceCreateIOProcIDWithBlock(&deviceProcID, aggregateDeviceID, queue, ioBlock)
AudioDeviceStart(aggregateDeviceID, deviceProcID)
// ...
AudioDeviceStop(aggregateDeviceID, deviceProcID)
AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
```

Сигнатура блоку: `(inNow, inInputData, inInputTime, outOutputData, inOutputTime)`.
AudioCap використовує лише `inInputData` (`UnsafePointer<AudioBufferList>`):

```swift
guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil)
else { throw "Failed to create PCM buffer" }
try currentFile.write(from: buffer)
```

`format` — `AVAudioFormat(streamDescription:)` з ASBD tap-у.

### Відмінності нашої реалізації

1. **Розкладка каналів.** У нас у `inInputData` буде **кілька буферів**: мікрофонні
   канали і tap-канали. 🔬 Порядок буферів і відповідність «буфер ↔ sub-device / tap»
   визначаємо **емпірично на GATE-1** (надрукувати `mNumberBuffers`,
   `mNumberChannels`, `mDataByteSize` кожного буфера і формат aggregate-стріму).
   Ім'я API вгадувати не можна — рахувати з реального дампу.
2. **Формат файлів.** ТЗ вимагає LPCM **16-bit** 48 кГц, tap віддає float32.
   `AVAudioFile(forWriting:settings:)` з `AVLinearPCMBitDepthKey: 16` конвертує при
   `write(from:)` автоматично (processing format ≠ file format). Перевірити довжину
   на GATE-1.
3. **Таймлайн.** AudioCap просто пише буфери підряд; ми пропускаємо кожен буфер через
   `TimelineAccountant` (Task 5) і доповнюємо розриви тишею —
   семплів = тривалість × 48000 (інваріант спеки §3). `inInputTime`
   (`AudioTimeStamp`) — джерело часових міток; 🔬 звірити на GATE-1, що
   `mHostTime`/`mSampleTime` монотонні на aggregate.
4. **Мовчазна інвалідація.** `ProcessTap` тримає `invalidationHandler` — CoreAudio
   може прибити tap (зміна пристрою). У нас це вхід у watchdog + rebuild (Task 12).

---

## 4a. Що ВЖЕ підтверджено на залізі (спайк `~/dev/spike-tap`, 06.08)

Власний CLI-спайк (`main.swift`, зібраний `swiftc` **без Xcode**, ad-hoc підпис,
Info.plist вшитий через `-sectcreate __TEXT __info_plist`) на цьому маку показав:

| Крок | Результат |
|---|---|
| `translatePIDToProcessObject(getpid())` | ✅ повертає валідний object ID |
| `CATapDescription(stereoGlobalTapButExcludeProcesses:)` | ✅ **global tap створюється**, `err = 0` |
| `kAudioTapPropertyFormat` | ✅ **48000 Гц, 2 канали, float32** (flags=9, bits=32) — збігається з форматом ТЗ по частоті |
| `AudioHardwareCreateAggregateDevice` (output + tap) | ✅ створюється, `err = 0` |
| `AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart` | ✅ **749 колбеків за 8 с** |
| Форма буфера в колбеку | ✅ один буфер `2ch / 4096 B` = 512 фреймів float32 |
| Цілісність таймлайна | ✅ **383488 фреймів за 7.99 с** — рівно 48000/с, розривів немає |
| Вміст семплів | ❌ **усі нулі** (peak = 0, RMS = 0) при реально відтворюваному звуці |

**Точні Swift-сигнатури (виправлені компілятором, не з памʼяті):**

```swift
// приймає [AudioObjectID], НЕ [NSNumber] — попри NSArray<NSNumber*> в ObjC-хедері
let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcessObjectID])
desc.muteBehavior = CATapMuteBehavior.unmuted   // крапковий синтаксис не виводиться
```

**Причина тиші — TCC, і це діагностовано, а не припущено:** база
`~/Library/Application Support/com.apple.TCC/TCC.db` **не містить жодного запису**
для `kTCCServiceAudioCapture`. Тобто дозвіл ніколи не запитувався: процес,
запущений із SSH-сесії, не належить до GUI-сесії (Aqua), тому TCC-промпт не
показується, а API мовчки віддає тишу — без помилки.

**Підтвердження (та сама сесія, пізніше):** після запуску спайка з GUI-сесії
(`osascript` → Terminal) у системі зʼявився процес
`UserNotificationCenter` **о 13:37:43 — через 1 секунду після Terminal (13:37:42)**.
Це і є TCC-діалог, який чекає на відповідь на екрані VNC. Поки він висить,
`AudioDeviceStart` повертає `noErr`, але **IO-колбеки не приходять взагалі**
(0 замість 749) — тобто незакритий діалог блокує захоплення тихо, без помилки.
Це окремий діагностичний симптом, який варто розрізняти:

| Симптом | Значення |
|---|---|
| Колбеки йдуть, семпли нульові | дозвіл не запитаний / відхилений |
| Колбеків **немає взагалі** | висить незакритий TCC-діалог, або aggregate не стартував |

**Висновок для GATE-1:** уся CoreAudio-механіка на цьому хмарному маку **робоча**;
відкритим лишається виключно видача TCC-дозволу, яка вимагає взаємодії з GUI
(клік на VNC). Запуск спайка треба ініціювати **зсередини GUI-сесії**
(Terminal на VNC), а не по SSH.

## 5. Відкриті питання — валідуються на GATE-1 (Task 3 Step 2)

1. 🔬 Чи створюється aggregate з **input sub-device + tap** одночасно (AudioCap таке
   не робить)? Якщо CoreAudio відмовить — план Б: два aggregate з двома IO-процами
   і зшивання за host-time (гірше, але робоче; синхронність тоді доводиться
   вимірюванням, не побудовою).
2. 🔬 Що ставити в `kAudioAggregateDeviceMainSubDeviceKey` — output чи input? Main
   sub-device задає годинник. Кандидат: output (як у AudioCap), mic — з
   `kAudioSubDeviceDriftCompensationKey: true`.
3. 🔬 Порядок і розкладка буферів у `inInputData`.
4. 🔬 Чи працює tap на **хмарному маку без фізичного аудіовиходу** (тут default
   output — `Mac mini Speakers`, фізичного мікрофона **немає взагалі**). Мікрофонна
   частина стенда закривається BlackHole (дев-залежність, не продуктова).
5. 🔬 Поведінка TCC-промпту в VNC-сесії (ризик спеки §8).

---

## 6. Що беремо / не беремо з AudioCap

| Беремо | Не беремо |
|---|---|
| Точні виклики tap + aggregate, порядок знищення | Приватний TCC SPI (`ENABLE_TCC_SPI`) |
| `CoreAudioUtils` — generic `AudioObjectGetPropertyData`-хелпери (перепишемо своє) | Per-process tap (`stereoMixdownOfProcesses`) — у нас global |
| `AVAudioPCMBuffer(bufferListNoCopy:)` в IO-колбеку | Запис «як є» без обліку таймлайна |
| `kAudioAggregateDeviceIsPrivateKey: true` | App Sandbox (нам не потрібен без App Store) |
