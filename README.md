# HotspotGuard

Menu bar watchdog для macOS: стежить за інтернет-з'єднанням і автоматично
перепідключається до заданого Wi-Fi хотспота, коли зв'язок пропадає.

Іконка в menu bar показує стан: **зелена** — інтернет є, **жовта** — триває
спроба перепідключення, **червона** — з'єднання втрачено, **сіра** — моніторинг
вимкнено.

## Мінімальна версія: macOS 14.0 (Sonoma)

Не 13, і це усвідомлений вибір:

- **`@Observable`** (Observation framework) — macOS 14+. Саме він дозволяє
  `HotspotGuardCore` не залежати від SwiftUI/Combine: той самий
  `ConnectionManager` живить menu bar сьогодні і зможе живити CLI завтра.
- **CoreWLAN змінився в Sonoma**: з 14.0 читання `CWInterface.ssid()` і
  `scanForNetworks` вимагають авторизації геолокації. Таргет 14 = одна модель
  поведінки без розгалужень `if #available`.
- **`MenuBarExtra(.window)`** на macOS 13 має баги з фокусом `TextField`, а тут
  поля вводу живуть прямо в дропдауні.

`SMAppService` доступний з 13, тож не він визначає нижню межу.

## Збірка

Xcode **не потрібен** — вистачає Command Line Tools (`xcode-select --install`).

```bash
./scripts/build-app.sh
```

Результат: `.build/HotspotGuard.app`, підписаний ad-hoc.

Корисні варіанти:

```bash
./scripts/build-app.sh --install --run
```

```bash
CONFIGURATION=debug ./scripts/build-app.sh
```

```bash
DEVELOPER_ID="Developer ID Application: Ім'я (TEAMID)" ./scripts/build-app.sh
```

### Чому потрібен скрипт, а не просто `swift build`

SwiftPM видає голий бінарник, а menu bar застосунку потрібен бандл: `LSUIElement`,
рядки-пояснення для Location і bundle identifier живуть в `Info.plist`, а TCC,
Keychain і `SMAppService` ідентифікують застосунок саме за identifier + підписом.
Скрипт збирає, загортає і підписує.

### Якщо у вас є Xcode

Проєкт відкривається як SwiftPM package: `File → Open…` і вибрати теку
`hotspot-guard`. Схема `HotspotGuard` збереться, але для повноцінного `.app`
все одно потрібен `build-app.sh` (Xcode не знає про наш `Info.plist`).

## Тести

```bash
swift run hotspotguard-selftest
```

54 перевірки: `AppSettings`, `EventLog`, `KeychainHelper`, `TCPConnectivityProbe`
і стан-машина `ConnectionManager` (успішний реконект, captive portal, серія
невдач із однією нотифікацією, відсутній SSID/пароль, start/stop).

Тести — це executable, а не `.testTarget`, бо і XCTest, і swift-testing
поставляються всередині Xcode. На машині з самими Command Line Tools
`swift test` не працює взагалі, а `swift run hotspotguard-selftest` — працює.
Вихідний код повертає ненульовий статус при падінні, тож для CI цього досить.

## Дозволи

### Location — обов'язковий

При першому запуску macOS спитає дозвіл на геолокацію. Це не помилка і не
телеметрія.

Набір Wi-Fi мереж навколо вас визначає ваше положення з точністю до кварталу —
саме так працює база геолокації Apple. Тому з macOS Sonoma система закриває
доступ до будь-якого API, що показує сусідні мережі, за Location Services. Без
цього дозволу:

- `CWInterface.ssid()` повертає `nil` навіть коли Wi-Fi підключений — ви не
  побачите назву мережі;
- `scanForNetworks` падає з «not permitted» — а це повністю блокує
  перепідключення.

Застосунок ніколи не читає координати; він лише запитує дозвіл, щоб CoreWLAN
почав відповідати.

Якщо випадково відмовили: **System Settings › Privacy & Security › Location
Services › HotspotGuard**.

### Notifications

Запитується при першому запуску. Використовується лише щоб попередити після
трьох невдалих спроб поспіль. Відмова нічого не ламає — події все одно
пишуться в History.

## Відомі обмеження

**CoreWLAN не гарантує повну відсутність діалогів.** `associate(to:password:)`
працює тихо для мережі, яку macOS уже знає, але приєднання до невідомої мережі
може викликати системний запит авторизації. Обхід: один раз підключіться до
хотспота вручну — мережа потрапить у список збережених, і подальші реконекти
йтимуть без питань. Це все одно значно краще за `networksetup
-setairportnetwork`, який просить пароль адміністратора **щоразу**.

**Launch at Login на ad-hoc підписі часто не працює.** `SMAppService.register()`
повертає помилку, бо launchd перевіряє підпис перед встановленням login item.
Помилка показується в меню, а не ковтається. Обхід — додати застосунок вручну:
**System Settings › General › Login Items › +**. З реальним Developer ID
перемикач працює штатно.

**Ad-hoc підпис змінюється при кожній перезбірці.** macOS сприймає новий білд як
інший застосунок, тож дозвіл на Location доведеться давати знову, а Keychain
може перепитати доступ. З постійним Developer ID цього немає.

**App Sandbox вимкнено.** CoreWLAN `associate` під сендбоксом потребує
entitlements, недоступних без платного Developer-акаунта.

## Архітектура

Два таргети, і межа між ними — не косметична: компілятор фізично не дасть
затягнути AppKit у ядро.

```
Sources/
├── HotspotGuardCore/          # жодного імпорту AppKit/SwiftUI
│   ├── ConnectionManager.swift    # стан-машина + цикл моніторингу
│   ├── ConnectivityProbe.swift    # protocol + NWConnection-реалізація
│   ├── WiFiController.swift       # protocol + CoreWLAN-реалізація
│   ├── KeychainHelper.swift       # Security framework
│   ├── LocationAuthorization.swift
│   ├── Notifications.swift        # protocol + UserNotifications
│   ├── Settings.swift             # AppSettings (UserDefaults)
│   ├── EventLog.swift             # кільцевий буфер на 20 подій
│   └── Defaults.swift             # константи
└── HotspotGuard/              # UI
    ├── App.swift                  # @main, AppModel, MenuBarExtra
    ├── MenuBarView.swift          # дропдаун
    ├── HistoryView.swift          # вікно History
    ├── LaunchAtLogin.swift        # SMAppService
    └── StatusIcon.swift           # кольорова іконка
```

`ConnectivityProbe` і `WiFiController` — протоколи, і саме це робить логіку
тестованою: підставляємо фейк, який каже «інтернету немає», і перевіряємо, що
менеджер спробував перепідключитись рівно раз. Інакше перевірити хоч щось можна
було б лише сидячи біля справжнього хотспота.

CLI-фронтенд у майбутньому — це третій таргет, що лінкує тільки `HotspotGuardCore`;
`ConnectionManager.tick()` уже публічний саме для одноразової перевірки без циклу.

### Чому TCP, а не ICMP ping

Справжній `ping` потребує raw-сокетів і власноруч зібраного ICMP-пакета — і при
цьому відповідає не на те питання. Captive portal спокійно пропускає ICMP,
блокуючи все інше, тому ping каже «онлайн» саме там, де ви офлайн. Завершений
TCP-хендшейк до зовнішнього хоста — сильніший сигнал і не потребує привілеїв.
Пробуються `1.1.1.1:443` і `8.8.8.8:53` паралельно, перший успіх виграє.

### Де що зберігається

| Дані | Де | Чому |
| --- | --- | --- |
| SSID, інтервал, стан моніторингу | `UserDefaults` | несекретне |
| Пароль хотспота | Keychain (`kSecClassGenericPassword`) | `UserDefaults` — це звичайний plist, який читає будь-який процес користувача |

Ключ Keychain — пара (service = bundle ID, account = SSID), тож паролі різних
хотспотів не перетирають один одного. Пароль ніколи не потрапляє в лог подій.

## Використання

1. Клік на іконку в menu bar.
2. **Hotspot** — назва мережі (наприклад, ім'я вашого iPhone).
3. **Password** — введіть і натисніть **⏎** або ✓. Під полем з'явиться
   «Saved in Keychain» — доки цього напису немає, пароль не збережений.
4. **Every** — інтервал перевірки, 5–120 с (за замовчуванням 10).
5. **Start** — запустити моніторинг. Стан зберігається між запусками.

**Reconnect now** — ручний тригер. **History…** — усі 20 останніх подій.
