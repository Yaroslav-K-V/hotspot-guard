# HotspotGuardCore — public API

Generated from the compiler's symbol graph by `scripts/generate-api-docs.sh`. Do not edit by hand; CI regenerates this file and fails the build when it drifts from the code.

## `AppSettings`

_class_

```swift
@MainActor final class AppSettings
```

User-facing configuration, persisted in `UserDefaults`.

Named `AppSettings` rather than `Settings` because SwiftUI already exports a
`Settings` scene type, and the collision is ambiguous at every use site in
the UI layer.

The Wi-Fi password is deliberately absent from this type. `UserDefaults` is
a plain plist on disk that any process running as the user can read, so the
password lives in the Keychain instead — see ``KeychainHelper``.

**Members:**

### `init(defaults:)`

_initializer_

```swift
@MainActor init(defaults: UserDefaults = .standard)
```

### `checkInterval`

_property_

```swift
@MainActor var checkInterval: TimeInterval { get set }
```

Seconds between connectivity checks, clamped to a sane range.

### `isConfigured`

_property_

```swift
@MainActor var isConfigured: Bool { get }
```

### `monitoringEnabled`

_property_

```swift
@MainActor var monitoringEnabled: Bool { get set }
```

Whether monitoring should resume automatically on next launch.

### `networks`

_property_

```swift
@MainActor var networks: [HotspotNetwork] { get set }
```

Configured networks, in the order they should be tried.

Stored as JSON rather than as a plist array of dictionaries so the shape
is defined by `HotspotNetwork` alone, and adding a field later does not
mean hand-writing plist coercion.

### `primarySSID`

_property_

```swift
@MainActor var primarySSID: String { get }
```

SSID of the highest-priority network, or `""` when nothing is set up.

Convenience for the many places that just need something to display.


## `AppleCaptivePortalDetector`

_struct_

```swift
struct AppleCaptivePortalDetector
```

Uses Apple's own captive-portal endpoint — the one macOS itself probes.

It returns a tiny, fixed document. Anything else (a redirect, a login page,
an error) means something is sitting between this Mac and the internet.

**Members:**

### `init()`

_initializer_

```swift
init()
```

### `isIntercepted(timeout:)`

_method_

```swift
func isIntercepted(timeout: TimeInterval) async -> Bool
```


## `CaptivePortalDetector`

_protocol_

```swift
protocol CaptivePortalDetector : Sendable
```

Detects whether HTTP is being intercepted by a login portal.


## `ConnectionManager`

_class_

```swift
@MainActor final class ConnectionManager
```

Owns the monitor-and-reconnect loop.

Deliberately free of AppKit and SwiftUI: it is `@Observable` (Observation,
not Combine), so SwiftUI can bind to it directly today while the same type
stays usable from a headless CLI. All collaborators are injected as
protocols, which is what makes the loop testable without real Wi-Fi.

`@MainActor` because state is read by the UI on every tick; the slow work
(probing, scanning, associating) happens inside the injected actors/queues,
so the main thread is never blocked.

**Members:**

### `State`

_enum_

```swift
enum State
```

### `init(settings:log:probe:wifi:notifier:pathObserver:sleepObserver:probeTimeout:postAssociationDelay:passwordProvider:)`

_initializer_

```swift
@MainActor init(settings: AppSettings, log: EventLog, probe: ConnectivityProbe = TCPConnectivityProbe(), wifi: WiFiController = CoreWLANController(), notifier: NotificationPresenter = UserNotificationPresenter(), pathObserver: NetworkPathObserver? = SystemNetworkPathObserver(), sleepObserver: SleepWakeObserver? = nil, probeTimeout: TimeInterval = Defaults.probeTimeout, postAssociationDelay: Duration = Defaults.postAssociationDelay, passwordProvider: @escaping @MainActor (String) -> String?)
```

### `handlePathChange(isSatisfied:)`

_method_

```swift
@MainActor func handlePathChange(isSatisfied: Bool)
```

Reacts to the system reporting a changed route.

The path only says whether a route *exists* — a captive portal looks
perfectly satisfied — so this never decides connectivity itself. It just
pulls the next check forward, which is what makes a five-minute backoff
acceptable: when Wi-Fi actually comes back, the check happens now rather
than at the end of the backoff.

### `handleSleep()`

_method_

```swift
@MainActor func handleSleep()
```

Suspends checking across sleep.

`Task.sleep` is not a wall clock: across a system sleep its deadline can
pass unnoticed and fire the moment the machine wakes, before the Wi-Fi
interface has re-associated. That produces a guaranteed false "offline"
on every single wake, and — worse — an immediate pointless reconnect.

### `handleWake()`

_method_

```swift
@MainActor func handleWake()
```

Resumes after wake, deliberately not immediately.

Wi-Fi needs a few seconds to re-associate and get a DHCP lease. Checking
the instant the lid opens reliably reports a failure that fixes itself
unaided a moment later.

### `reconnectNow()`

_method_

```swift
@MainActor func reconnectNow() async
```

Manual "Reconnect now" trigger.

### `restartIfRunning()`

_method_

```swift
@MainActor func restartIfRunning()
```

Applies a changed check interval to a running loop.

The loop reads the interval once per iteration, so without this a change
made during a long sleep would not take effect until that sleep ended —
confusing when dragging a slider from 120s to 5s.

### `start()`

_method_

```swift
@MainActor func start()
```

### `stop()`

_method_

```swift
@MainActor func stop()
```

### `tick()`

_method_

```swift
@MainActor func tick() async
```

Runs a single check-and-maybe-reconnect cycle.

Exposed so a CLI front end can do a one-shot check without starting the
loop, and so tests can drive cycles deterministically. Returns without
doing anything if a cycle is already in flight.

### `consecutiveFailures`

_property_

```swift
@MainActor var consecutiveFailures: Int { get set }
```

Failed reconnect attempts since the last success.

### `currentAttemptSSID`

_property_

```swift
@MainActor var currentAttemptSSID: String? { get set }
```

Network currently being tried, while sweeping the priority list.

### `currentSSID`

_property_

```swift
@MainActor var currentSSID: String? { get set }
```

SSID currently joined, or `nil` when unknown (also `nil` without
Location authorization — see ``LocationAuthorization``).

### `effectiveCheckInterval`

_property_

```swift
@MainActor var effectiveCheckInterval: TimeInterval { get }
```

Seconds until the next scheduled check, after backoff.

Equal to the configured interval while healthy; doubles per consecutive
failure up to ``Defaults/maximumBackoffInterval``.

### `isAsleep`

_property_

```swift
@MainActor var isAsleep: Bool { get set }
```

`true` between `willSleep` and `didWake`, while checking is suspended.

### `isBackingOff`

_property_

```swift
@MainActor var isBackingOff: Bool { get }
```

`true` when checks are currently slowed down by repeated failures.

### `isRunning`

_property_

```swift
@MainActor var isRunning: Bool { get }
```

### `isWorking`

_property_

```swift
@MainActor var isWorking: Bool { get set }
```

`true` while a check or reconnect is in flight.

`@MainActor` serialises *threads*, not *tasks*: an `async` method that
suspends at an `await` lets another task run on the same actor. Without
this flag, pressing "Reconnect now" while a scheduled tick was awaiting
its probe started a second scan-and-associate on the same interface, and
could count one recovery twice.

### `lastCheck`

_property_

```swift
@MainActor var lastCheck: Date? { get set }
```

When the last connectivity check ran.

### `lastError`

_property_

```swift
@MainActor var lastError: String? { get set }
```

Most recent error, for display in the UI.

### `lastLatencyMilliseconds`

_property_

```swift
@MainActor var lastLatencyMilliseconds: Int? { get set }
```

Handshake time of the most recent successful check, in milliseconds.

### `log`

_property_

```swift
@MainActor let log: EventLog
```

### `medianLatencyMilliseconds`

_property_

```swift
@MainActor var medianLatencyMilliseconds: Int? { get }
```

Median of ``recentLatencies``.

Median rather than mean because one 2000ms outlier should not redraw
the whole picture.

### `recentLatencies`

_property_

```swift
@MainActor var recentLatencies: [Int] { get set }
```

Recent latency samples, oldest first, for the trend line.

Kept in memory only — the point is the shape of the last few minutes,
not a permanent record.

### `reconnectCount`

_property_

```swift
@MainActor var reconnectCount: Int { get set }
```

Successful reconnects since launch.

### `state`

_property_

```swift
@MainActor var state: State { get set }
```

### `summarise(candidates:attempted:missingPassword:notOnAir:)`

_type.method_

```swift
@MainActor static func summarise(candidates: Int, attempted: Int, missingPassword: [String], notOnAir: [String]) -> String
```

Turns the outcome of a full sweep into one line a person can act on.

"Reconnect failed" on its own says nothing about which of four networks
was the problem, or whether the problem is a missing password rather
than absent hardware.


## `ConnectivityProbe`

_protocol_

```swift
protocol ConnectivityProbe : Sendable
```

Answers one question: can this machine actually reach the internet?

A protocol rather than a concrete type so ``ConnectionManager`` can be
exercised against a fake that reports "offline" on demand — testing the
reconnection logic otherwise requires physically dropping Wi-Fi.


## `ConnectivityResult`

_struct_

```swift
struct ConnectivityResult
```

What a connectivity check found.

Replaces the earlier plain `Bool`, which conflated two states that call for
opposite responses: "there is no internet, reconnect" and "you are online
but a portal wants you to log in, do NOT reconnect — reconnecting would drop
the very session the login page lives on".

**Members:**

### `Status`

_enum_

```swift
enum Status
```

### `!=(_:_:)`

_func.op_

```swift
static func != (lhs: Self, rhs: Self) -> Bool
```

Returns a Boolean value indicating whether two values are not equal.

Inequality is the inverse of equality. For any values `a` and `b`, `a != b`
implies that `a == b` is `false`.

This is the default implementation of the not-equal-to operator (`!=`)
for any type that conforms to `Equatable`.

- Parameters:
  - lhs: A value to compare.
  - rhs: Another value to compare.

### `init(status:latency:respondingHost:)`

_initializer_

```swift
init(status: Status, latency: Duration? = nil, respondingHost: String? = nil)
```

### `isReachable`

_property_

```swift
var isReachable: Bool { get }
```

`true` only for a genuinely usable connection.

A captive portal is deliberately not "reachable": traffic does not get
out, so anything that means "we are fine" must not fire here.

### `latency`

_property_

```swift
let latency: Duration?
```

Round-trip time of the TCP handshake that answered.

The interesting part is not the current value but its trend: a link
usually degrades — 30ms, then 400ms, then nothing — well before it
drops. `nil` when nothing answered.

### `latencyMilliseconds`

_property_

```swift
var latencyMilliseconds: Int? { get }
```

Milliseconds, for display and logging.

### `respondingHost`

_property_

```swift
let respondingHost: String?
```

Which endpoint answered, for diagnostics.

### `status`

_property_

```swift
let status: Status
```

### `offline`

_type.property_

```swift
static let offline: ConnectivityResult
```


## `CoreWLANController`

_class_

```swift
final class CoreWLANController
```

CoreWLAN-backed implementation.

CoreWLAN is used rather than shelling out to `networksetup` because
`networksetup -setairportnetwork` prompts for administrator credentials on
every invocation, which defeats the point of an unattended watchdog.

Caveat worth knowing: `associate(to:password:)` is quiet for a network
macOS already knows, but joining an unknown network can still raise a system
authorization dialog. Joining the hotspot manually once puts it in the
preferred-networks list and makes subsequent reconnects silent.

**Members:**

### `init()`

_initializer_

```swift
init()
```

### `associate(ssid:password:)`

_method_

```swift
func associate(ssid: String, password: String) async throws
```

### `currentSSID()`

_method_

```swift
func currentSSID() async -> String?
```

### `isPoweredOn()`

_method_

```swift
func isPoweredOn() async -> Bool
```

### `normalize(_:)`

_type.method_

```swift
static func normalize(_ ssid: String) -> String
```

Folds away the differences that are invisible on screen, then
lowercases: matching a hand-typed name against what is on the air is
case-insensitive, unlike a Keychain key (see ``SSIDKey``).


## `CredentialsStore`

_class_

```swift
@MainActor final class CredentialsStore
```

Owns hotspot passwords: what is stored, what is being typed, and the rules
connecting the two.

Extracted from the UI layer deliberately. These rules are not UI-specific — a
CLI would need the same ones — and while they lived in `AppModel` they were
untestable, which is exactly where the "editing the SSID silently discards
the typed password" bug survived.

**Members:**

### `init(storage:)`

_initializer_

```swift
@MainActor init(storage: PasswordStorage = KeychainPasswordStorage())
```

### `beginEditing(_:)`

_method_

```swift
@MainActor func beginEditing(_ ssid: String)
```

Points the draft at a network, discarding any draft for a different one.

Switching targets is the one case where dropping the text is correct:
committing it to the newly selected network would file the password
under the wrong SSID.

### `cancelEditing()`

_method_

```swift
@MainActor func cancelEditing()
```

### `forget(_:)`

_method_

```swift
@discardableResult @MainActor func forget(_ ssid: String) -> String?
```

Removes the stored password for `ssid`, e.g. when its network is deleted.

### `hasPassword(for:)`

_method_

```swift
@MainActor func hasPassword(for ssid: String) -> Bool
```

Whether a password is stored for `ssid`.

### `hasUnsavedDraft(for:)`

_method_

```swift
@MainActor func hasUnsavedDraft(for ssid: String) -> Bool
```

`true` when there is an uncommitted draft for `ssid`.

### `invalidateCache()`

_method_

```swift
@MainActor func invalidateCache()
```

Drops cached presence flags, forcing the next query to hit storage.

### `isEditing(_:)`

_method_

```swift
@MainActor func isEditing(_ ssid: String) -> Bool
```

`true` when the password field is currently aimed at `ssid`.

A method rather than comparing `draftSSID` directly: that value is
canonical while the list holds SSIDs as typed, so `==` would quietly
return false for exactly the names normalisation exists to handle.

### `isMissingPassword(for:)`

_method_

```swift
@MainActor func isMissingPassword(for ssid: String) -> Bool
```

A network that is configured but has no password — the misconfiguration
that looks fine until a reconnect fails.

### `password(for:)`

_method_

```swift
@MainActor func password(for ssid: String) -> String?
```

The password to authenticate with, or `nil` when there is none.

### `save()`

_method_

```swift
@discardableResult @MainActor func save() -> String?
```

Commits the draft to storage.

- Returns: a message worth logging, or `nil` if nothing happened.

### `draft`

_property_

```swift
@MainActor var draft: String { get set }
```

Password being typed, and which network it is for.

Held only until committed by ``save()``. Never persisted anywhere else,
and never written to the event log.

### `draftSSID`

_property_

```swift
@MainActor var draftSSID: String? { get set }
```

### `hasAnyUnsavedDraft`

_property_

```swift
@MainActor var hasAnyUnsavedDraft: Bool { get }
```

### `lastError`

_property_

```swift
@MainActor var lastError: String? { get set }
```

Last storage error, for display.


## `Defaults`

_enum_

```swift
enum Defaults
```

Tunable constants, in one place.

Deliberately a plain `enum` outside any actor: these are used as default
parameter values, which are evaluated in the caller's isolation context. A
`static let` on a `@MainActor` type cannot be read from a `nonisolated`
caller, so putting them here keeps the defaults usable everywhere.

**Members:**

### `checkInterval`

_type.property_

```swift
static let checkInterval: TimeInterval
```

Seconds between connectivity checks.

### `degradedLatencyMilliseconds`

_type.property_

```swift
static let degradedLatencyMilliseconds: Int
```

Latency above which the connection is flagged as degraded.

Chosen as the point where interactive work (SSH, calls) starts to feel
wrong.

### `eventLogCapacity`

_type.property_

```swift
static let eventLogCapacity: Int
```

Number of events kept in the session history.

### `failureNotificationThreshold`

_type.property_

```swift
static let failureNotificationThreshold: Int
```

Consecutive failed reconnects before the user is notified.

### `latencySampleCount`

_type.property_

```swift
static let latencySampleCount: Int
```

How many latency samples to keep for the trend line.

At a 10s interval this is roughly the last five minutes.

### `maximumBackoffDoublings`

_type.property_

```swift
static let maximumBackoffDoublings: Int
```

How many times the interval may double (2^5 = 32x the base interval).

### `maximumBackoffInterval`

_type.property_

```swift
static let maximumBackoffInterval: TimeInterval
```

Ceiling on the gap between checks while reconnection keeps failing.

Without backoff, a hotspot that is simply switched off costs a full
scan-and-associate cycle every `checkInterval` seconds, forever. A Wi-Fi
scan sweeps the radio across channels: it is not free for the battery,
and on some adapters it disturbs the current association. Five minutes
keeps an idle failure state cheap while staying responsive enough —
and the path monitor short-circuits the wait whenever a route actually
appears, so a long backoff does not mean a long wait in practice.

### `maximumCheckInterval`

_type.property_

```swift
static let maximumCheckInterval: TimeInterval
```

### `minimumCheckInterval`

_type.property_

```swift
static let minimumCheckInterval: TimeInterval
```

### `minimumPathTriggerInterval`

_type.property_

```swift
static let minimumPathTriggerInterval: TimeInterval
```

Minimum gap between checks triggered by network path changes, so a
flapping interface cannot drive a scan storm.

### `postAssociationDelay`

_type.property_

```swift
static let postAssociationDelay: Duration
```

Wait after associating before re-probing, so DHCP can finish.

Too short and a successful reconnect reads as a failure.

### `postWakeDelay`

_type.property_

```swift
static let postWakeDelay: Duration
```

Grace period after waking before checking again, so Wi-Fi has time to
re-associate and pick up a DHCP lease.

### `probeTimeout`

_type.property_

```swift
static let probeTimeout: TimeInterval
```

How long a single connectivity probe may take.


## `EventLog`

_class_

```swift
@MainActor final class EventLog
```

Fixed-capacity ring buffer of recent events, newest first.

Never pass a password to ``append(_:_:)`` — entries are rendered in the UI
and are meant to be safe to screenshot.

**Members:**

### `init(capacity:)`

_initializer_

```swift
@MainActor init(capacity: Int = Defaults.eventLogCapacity)
```

### `append(_:_:)`

_method_

```swift
@MainActor func append(_ level: LogEvent.Level, _ message: String)
```

### `clear()`

_method_

```swift
@MainActor func clear()
```

### `capacity`

_property_

```swift
@MainActor let capacity: Int
```

### `events`

_property_

```swift
@MainActor var events: [LogEvent] { get set }
```


## `FeatureFlag`

_enum_

```swift
enum FeatureFlag
```

A runtime feature flag: an ops-level on/off that does not need a rebuild.

Flags are not user settings. Settings are choices the app exposes; flags
are rollbacks — a way to turn a misbehaving feature off on one machine
(or during QA) without shipping a new build.

**Members:**

### `captivePortalDetection`

_case_

```swift
case captivePortalDetection
```

The captive-portal probe after a successful association. Off means
"associated" is treated as "online" without asking Apple's endpoint.

### `connectionHistory`

_case_

```swift
case connectionHistory
```

The session-history window and the "History…" entry point to it.

### `!=(_:_:)`

_func.op_

```swift
static func != (lhs: Self, rhs: Self) -> Bool
```

Returns a Boolean value indicating whether two values are not equal.

Inequality is the inverse of equality. For any values `a` and `b`, `a != b`
implies that `a == b` is `false`.

This is the default implementation of the not-equal-to operator (`!=`)
for any type that conforms to `Equatable`.

- Parameters:
  - lhs: A value to compare.
  - rhs: Another value to compare.

### `init(rawValue:)`

_initializer_

```swift
init?(rawValue: String)
```

### `hash(into:)`

_method_

```swift
func hash(into hasher: inout Hasher)
```

### `defaultValue`

_property_

```swift
var defaultValue: Bool { get }
```

Value when neither override exists — the behaviour the app ships with.

### `hashValue`

_property_

```swift
var hashValue: Int { get }
```


## `FeatureFlags`

_struct_

```swift
struct FeatureFlags
```

Resolves ``FeatureFlag`` values through three layers, first match wins.

1. **Launch argument** `-<flag> true|false`, for QA and selftests:
   `.build/HotspotGuard.app/Contents/MacOS/HotspotGuard -captivePortalDetection false`
2. **UserDefaults** key `flags.<flag>`, a per-machine ops toggle:
   `defaults write com.example.HotspotGuard flags.captivePortalDetection -bool false`
3. **Built-in default** (``FeatureFlag/defaultValue``).
`@unchecked Sendable` because `UserDefaults` predates conformance:
Apple documents it as thread-safe, and `arguments` is an immutable copy.

**Members:**

### `init(defaults:arguments:)`

_initializer_

```swift
init(defaults: UserDefaults = .standard, arguments: [String] = ProcessInfo.processInfo.arguments)
```

### `isEnabled(_:)`

_method_

```swift
func isEnabled(_ flag: FeatureFlag) -> Bool
```

Resolves a flag through the override layers down to its default.


## `HotspotNetwork`

_struct_

```swift
struct HotspotNetwork
```

One configured network, in priority order.

Holds no password: those live in the Keychain, keyed by SSID. Keeping the
identity here and the secret there is what lets this struct be `Codable` and
persisted to UserDefaults without leaking anything.

**Members:**

### `!=(_:_:)`

_func.op_

```swift
static func != (lhs: Self, rhs: Self) -> Bool
```

Returns a Boolean value indicating whether two values are not equal.

Inequality is the inverse of equality. For any values `a` and `b`, `a != b`
implies that `a == b` is `false`.

This is the default implementation of the not-equal-to operator (`!=`)
for any type that conforms to `Equatable`.

- Parameters:
  - lhs: A value to compare.
  - rhs: Another value to compare.

### `init(from:)`

_initializer_

```swift
init(from decoder: any Decoder) throws
```

### `init(id:ssid:)`

_initializer_

```swift
init(id: UUID = UUID(), ssid: String)
```

### `id`

_property_

```swift
let id: UUID
```

### `isConfigured`

_property_

```swift
var isConfigured: Bool { get }
```

### `ssid`

_property_

```swift
var ssid: String
```

### `trimmedSSID`

_property_

```swift
var trimmedSSID: String { get }
```

SSID with surrounding whitespace removed.


## `KeychainError`

_enum_

```swift
enum KeychainError
```

Errors surfaced by ``KeychainHelper``.

**Members:**

### `malformedData`

_case_

```swift
case malformedData
```

### `unexpectedStatus(_:)`

_case_

```swift
case unexpectedStatus(OSStatus)
```

### `!=(_:_:)`

_func.op_

```swift
static func != (lhs: Self, rhs: Self) -> Bool
```

Returns a Boolean value indicating whether two values are not equal.

Inequality is the inverse of equality. For any values `a` and `b`, `a != b`
implies that `a == b` is `false`.

This is the default implementation of the not-equal-to operator (`!=`)
for any type that conforms to `Equatable`.

- Parameters:
  - lhs: A value to compare.
  - rhs: Another value to compare.

### `errorDescription`

_property_

```swift
var errorDescription: String? { get }
```

### `failureReason`

_property_

```swift
var failureReason: String? { get }
```

### `helpAnchor`

_property_

```swift
var helpAnchor: String? { get }
```

### `localizedDescription`

_property_

```swift
var localizedDescription: String { get }
```

Retrieve the localized description for this error.

### `recoverySuggestion`

_property_

```swift
var recoverySuggestion: String? { get }
```


## `KeychainHelper`

_enum_

```swift
enum KeychainHelper
```

Thin wrapper over `SecItem*` for a single generic-password item per SSID.

Items are stored as `kSecClassGenericPassword` keyed by (service, account),
where service is the bundle identifier and account is the SSID. That means
switching hotspots keeps each password separately rather than overwriting.

Note for unsigned/ad-hoc-signed builds: macOS ties Keychain ACLs to the code
signature, so rebuilding the app changes its identity and the system will
prompt for permission again. Signing with a stable identity avoids this.

**Members:**

### `allAccounts(service:)`

_type.method_

```swift
static func allAccounts(service: String = defaultService) throws -> [String]
```

Every account name stored under `service`.

Needed because Keychain lookups fold Unicode differences while writes do
not: searching for "Anna's" finds an item stored as "Anna’s", but adding
under the typed spelling creates a *second* item. Listing the raw account
names is the only way to see that divergence and repair it.

### `allAccountsAndPasswords(service:)`

_type.method_

```swift
static func allAccountsAndPasswords(service: String = defaultService) throws -> [String : String]
```

Every account name and its password stored under `service`.

Fetches both the attributes and the data in a single query to avoid
N+1 lookups when migrating all stored keys.

### `deletePassword(service:account:)`

_type.method_

```swift
static func deletePassword(service: String = defaultService, account: String) throws
```

Removes the item.

Deleting something that is not there is not an error.

### `hasPassword(service:account:)`

_type.method_

```swift
static func hasPassword(service: String = defaultService, account: String) -> Bool
```

### `password(service:account:)`

_type.method_

```swift
static func password(service: String = defaultService, account: String) throws -> String?
```

Returns the stored password, or `nil` when no item exists.

### `setPassword(_:service:account:)`

_type.method_

```swift
static func setPassword(_ password: String, service: String = defaultService, account: String) throws
```

Stores or replaces the password for `account`.

Passing an empty string deletes the item — "no password" and "empty
password" are the same thing for our purposes, and keeping an empty
item around would make `hasPassword` lie.

### `defaultService`

_type.property_

```swift
static var defaultService: String { get }
```

Default service name.

Falls back to a fixed string when there is no bundle (e.g. `swift run`,
or a future CLI build).


## `KeychainPasswordStorage`

_struct_

```swift
struct KeychainPasswordStorage
```

Real storage: the login Keychain, via ``KeychainHelper``.

All reads and writes go through ``SSIDKey/normalize(_:)``, which is what
stops a network from acquiring two Keychain items that look the same.

**Members:**

### `init(service:)`

_initializer_

```swift
init(service: String? = nil)
```

### `migrateToNormalizedKeys()`

_method_

```swift
@discardableResult func migrateToNormalizedKeys() throws -> [String]
```

Rewrites any item whose account name is not in canonical form.

One-shot repair for items written before normalisation existed. Order
matters: the new item is written and verified *before* the old one is
removed, so an interruption can leave a harmless duplicate but never a
lost password.

- Returns: the account names that were rewritten.

### `password(for:)`

_method_

```swift
func password(for account: String) throws -> String?
```

### `setPassword(_:for:)`

_method_

```swift
func setPassword(_ password: String, for account: String) throws
```


## `LocationAuthorization`

_class_

```swift
@MainActor final class LocationAuthorization
```

**Members:**

### `init()`

_initializer_

```swift
@MainActor override convenience init()
```

### `init(manager:)`

_initializer_

```swift
@MainActor init(manager: any LocationManagerProtocol)
```

### `locationManagerDidChangeAuthorization(_:)`

_method_

```swift
nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager)
```

### `request(onChange:)`

_method_

```swift
@MainActor func request(onChange: (@MainActor (CLAuthorizationStatus) -> Void)? = nil)
```

Prompts if the user has not decided yet.

A no-op once decided — re-requesting after a denial does nothing, by
design of the system.

### `isAuthorized`

_property_

```swift
@MainActor var isAuthorized: Bool { get }
```

`true` when CoreWLAN will return real data.

### `status`

_property_

```swift
@MainActor var status: CLAuthorizationStatus { get }
```


## `LocationManagerProtocol`

_protocol_

```swift
@MainActor protocol LocationManagerProtocol : AnyObject
```

Requests the Location permission that CoreWLAN requires.

Why a Wi-Fi utility asks for your location, in short: the set of Wi-Fi
networks around you identifies where you are with street-level accuracy —
that is how Apple's own location database works. So since macOS Sonoma the
system gates the APIs that expose nearby-network information behind Location
Services. Concretely, without authorization:

  * `CWInterface.ssid()` returns `nil` even while connected, and
  * `CWInterface.scanForNetworks` fails with a "not permitted" error.

The app never reads your coordinates. It requests the permission solely so
CoreWLAN will answer, which is what `NSLocationUsageDescription` in
Info.plist tells the user.


## `LogEvent`

_struct_

```swift
struct LogEvent
```

A single timestamped entry in the session history.

**Members:**

### `Level`

_enum_

```swift
enum Level
```

### `!=(_:_:)`

_func.op_

```swift
static func != (lhs: Self, rhs: Self) -> Bool
```

Returns a Boolean value indicating whether two values are not equal.

Inequality is the inverse of equality. For any values `a` and `b`, `a != b`
implies that `a == b` is `false`.

This is the default implementation of the not-equal-to operator (`!=`)
for any type that conforms to `Equatable`.

- Parameters:
  - lhs: A value to compare.
  - rhs: Another value to compare.

### `init(id:timestamp:level:message:)`

_initializer_

```swift
init(id: UUID = UUID(), timestamp: Date = Date(), level: Level, message: String)
```

### `formattedTime`

_property_

```swift
var formattedTime: String { get }
```

`14:03:22` — history is only ever about the current session, so the date
part would be noise.

### `id`

_property_

```swift
let id: UUID
```

### `level`

_property_

```swift
let level: Level
```

### `message`

_property_

```swift
let message: String
```

### `timestamp`

_property_

```swift
let timestamp: Date
```


## `NetworkPathObserver`

_protocol_

```swift
protocol NetworkPathObserver : AnyObject, Sendable
```

Reports when the system's network route changes.

Complements polling rather than replacing it: `NWPathMonitor` knows whether
a route *exists*, not whether the internet is reachable through it — a
captive portal looks perfectly satisfied. So the path event is used as a
trigger to check now, and the probe still decides the answer.


## `NotificationPresenter`

_protocol_

```swift
protocol NotificationPresenter : Sendable
```

Delivers user-visible alerts.

Abstracted so tests can assert that a notification was raised without
actually posting one.


## `PasswordStorage`

_protocol_

```swift
protocol PasswordStorage : Sendable
```

Where hotspot passwords are kept.

A protocol so credential handling can be tested without touching the real
Keychain — which would otherwise make the tests depend on the login
keychain being unlocked and on the binary's code signature.


## `ProbeEndpoint`

_struct_

```swift
struct ProbeEndpoint
```

A TCP endpoint used as a reachability target.

**Members:**

### `!=(_:_:)`

_func.op_

```swift
static func != (lhs: Self, rhs: Self) -> Bool
```

Returns a Boolean value indicating whether two values are not equal.

Inequality is the inverse of equality. For any values `a` and `b`, `a != b`
implies that `a == b` is `false`.

This is the default implementation of the not-equal-to operator (`!=`)
for any type that conforms to `Equatable`.

- Parameters:
  - lhs: A value to compare.
  - rhs: Another value to compare.

### `init(host:port:)`

_initializer_

```swift
init(host: String, port: UInt16)
```

### `host`

_property_

```swift
let host: String
```

### `port`

_property_

```swift
let port: UInt16
```

### `defaults`

_type.property_

```swift
static let defaults: [ProbeEndpoint]
```

Cloudflare DNS over TLS and Google DNS.

Two providers so one operator having a bad day does not read as "the
internet is down".


## `SSIDKey`

_enum_

```swift
enum SSIDKey
```

Canonical form of an SSID when used as a storage key.

Deliberately *not* ``CoreWLANController/normalize(_:)``. That one lowercases,
which is right for matching a hand-typed name against what is on the air, but
wrong for a key: SSIDs are case-sensitive by standard, so `MyNet` and `mynet`
are different networks and must not share a password.

What this does fold is the invisible stuff (see
``String/foldingTypography()``) plus Unicode composition
differences — those look identical on screen and are pure trip hazards as
keys.

**Members:**

### `normalize(_:)`

_type.method_

```swift
static func normalize(_ ssid: String) -> String
```


## `SleepWakeObserver`

_protocol_

```swift
protocol SleepWakeObserver : AnyObject, Sendable
```

Reports when the machine goes to sleep and wakes up.

A protocol because the only way to observe this is `NSWorkspace`, which is
AppKit — and the whole point of this module is that it does not import
AppKit. The app supplies the real implementation; tests drive it by hand.


## `SystemNetworkPathObserver`

_class_

```swift
final class SystemNetworkPathObserver
```

`NWPathMonitor`-backed implementation.

**Members:**

### `init()`

_initializer_

```swift
init()
```

### `start(onChange:)`

_method_

```swift
func start(onChange: @escaping @Sendable (Bool) -> Void)
```

### `stop()`

_method_

```swift
func stop()
```


## `TCPConnectivityProbe`

_struct_

```swift
struct TCPConnectivityProbe
```

Reachability via a plain TCP handshake, using Network.framework.

Chosen over ICMP echo deliberately. A real `ping` needs raw sockets and a
hand-rolled ICMP packet, and it also answers the wrong question: a captive
portal will happily route ICMP while blocking everything else, so ping says
"online" on exactly the network where you are not. Completing a TCP
handshake to an off-network host is a stronger signal and needs no
privileges.

The TCP handshake alone still cannot see a portal that lets connections
through and rewrites HTTP, so a successful handshake is followed by a
``CaptivePortalDetector`` check.

**Members:**

### `init(endpoints:portalDetector:connector:fallback:)`

_initializer_

```swift
init(endpoints: [ProbeEndpoint] = ProbeEndpoint.defaults, portalDetector: CaptivePortalDetector? = AppleCaptivePortalDetector(), connector: Connector? = nil, fallback: FallbackCheck? = nil)
```

### `check(timeout:)`

_method_

```swift
func check(timeout: TimeInterval = Defaults.probeTimeout) async -> ConnectivityResult
```

### `Connector`

_typealias_

```swift
typealias Connector = @Sendable (ProbeEndpoint, TimeInterval) async -> ConnectivityResult
```

One connection attempt against an endpoint.

Injectable because "the network is down" cannot be faked reliably from
a test: even TEST-NET-1 (RFC 5737) answers when a VPN or transparent
proxy intercepts all connections. Tests pass a connector that reports
offline on demand instead of depending on the machine's network.

### `FallbackCheck`

_typealias_

```swift
typealias FallbackCheck = @Sendable (TimeInterval) async -> ConnectivityResult
```

Second opinion when every TCP handshake fails.

Injectable for the same reason as ``Connector``: the real check hits
the network, so tests stub it instead of depending on the machine
being offline.


## `UserNotificationCenterProtocol`

_protocol_

```swift
protocol UserNotificationCenterProtocol : Sendable
```

Abstracting UNUserNotificationCenter for testability.


## `UserNotificationCenterWrapper`

_struct_

```swift
struct UserNotificationCenterWrapper
```

A wrapper for the system UNUserNotificationCenter.

**Members:**

### `init(center:)`

_initializer_

```swift
init(center: UNUserNotificationCenter = .current())
```

### `add(_:)`

_method_

```swift
func add(_ request: UNNotificationRequest) async throws
```

### `requestAuthorization(options:)`

_method_

```swift
func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
```


## `UserNotificationPresenter`

_class_

```swift
final class UserNotificationPresenter
```

`UNUserNotificationCenter`-backed implementation.

**Members:**

### `init(center:isAvailable:)`

_initializer_

```swift
init(center: UserNotificationCenterProtocol = UserNotificationCenterWrapper(), isAvailable: @escaping @Sendable () -> Bool = { Bundle.main.bundleIdentifier != nil })
```

### `present(title:body:)`

_method_

```swift
func present(title: String, body: String) async
```

### `requestAuthorization()`

_method_

```swift
func requestAuthorization() async
```


## `WiFiController`

_protocol_

```swift
protocol WiFiController : Sendable
```

Wi-Fi operations the reconnection logic needs.

All members are `async` so a concrete implementation is free to do its work
off the calling thread — the CoreWLAN calls below are synchronous and slow
(a scan takes seconds), and must never run on the main thread.


## `WiFiError`

_enum_

```swift
enum WiFiError
```

**Members:**

### `associationFailed(_:)`

_case_

```swift
case associationFailed(String)
```

### `networkNotFound(_:visible:)`

_case_

```swift
case networkNotFound(String, visible: [String])
```

Carries what the scan *did* see, because "not in range" for a phone
lying on the desk is a useless thing to tell someone.

### `noInterface`

_case_

```swift
case noInterface
```

### `powerOnFailed(_:)`

_case_

```swift
case powerOnFailed(String)
```

### `scanFailed(_:)`

_case_

```swift
case scanFailed(String)
```

### `!=(_:_:)`

_func.op_

```swift
static func != (lhs: Self, rhs: Self) -> Bool
```

Returns a Boolean value indicating whether two values are not equal.

Inequality is the inverse of equality. For any values `a` and `b`, `a != b`
implies that `a == b` is `false`.

This is the default implementation of the not-equal-to operator (`!=`)
for any type that conforms to `Equatable`.

- Parameters:
  - lhs: A value to compare.
  - rhs: Another value to compare.

### `errorDescription`

_property_

```swift
var errorDescription: String? { get }
```

### `failureReason`

_property_

```swift
var failureReason: String? { get }
```

### `helpAnchor`

_property_

```swift
var helpAnchor: String? { get }
```

### `localizedDescription`

_property_

```swift
var localizedDescription: String { get }
```

Retrieve the localized description for this error.

### `recoverySuggestion`

_property_

```swift
var recoverySuggestion: String? { get }
```


## Freestanding symbols

### `add(_:)`

_method_

```swift
func add(_ request: UNNotificationRequest) async throws
```

### `associate(ssid:password:)`

_method_

```swift
func associate(ssid: String, password: String) async throws
```

Scans for `ssid` and joins it. Throws ``WiFiError`` on failure.

### `check(timeout:)`

_method_

```swift
func check(timeout: TimeInterval) async -> ConnectivityResult
```

Measures reachability, latency and captive-portal interception.

### `currentSSID()`

_method_

```swift
func currentSSID() async -> String?
```

SSID of the currently joined network, or `nil` if not associated.

Returns `nil` without Location authorization even when Wi-Fi is
connected — see ``LocationAuthorization``.

### `isIntercepted(timeout:)`

_method_

```swift
func isIntercepted(timeout: TimeInterval) async -> Bool
```

### `isPoweredOn()`

_method_

```swift
func isPoweredOn() async -> Bool
```

Whether the Wi-Fi radio is powered on.

### `password(for:)`

_method_

```swift
func password(for account: String) throws -> String?
```

### `present(title:body:)`

_method_

```swift
func present(title: String, body: String) async
```

### `requestAuthorization()`

_method_

```swift
func requestAuthorization() async
```

### `requestAuthorization(options:)`

_method_

```swift
func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
```

### `requestWhenInUseAuthorization()`

_method_

```swift
@MainActor func requestWhenInUseAuthorization()
```

### `setPassword(_:for:)`

_method_

```swift
func setPassword(_ password: String, for account: String) throws
```

Storing an empty string removes the entry.

### `start(onChange:)`

_method_

```swift
func start(onChange: @escaping @Sendable (Bool) -> Void)
```

Starts delivering changes. `isSatisfied` is `true` when a usable route
exists. Called on an arbitrary queue.

### `start(onSleep:onWake:)`

_method_

```swift
func start(onSleep: @escaping @Sendable () -> Void, onWake: @escaping @Sendable () -> Void)
```

### `stop()`

_method_

```swift
func stop()
```

### `stop()`

_method_

```swift
func stop()
```

### `authStatus`

_property_

```swift
@MainActor var authStatus: CLAuthorizationStatus { get }
```

### `delegate`

_property_

```swift
@MainActor var delegate: CLLocationManagerDelegate? { get set }
```

