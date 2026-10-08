import Foundation

/// A runtime feature flag: an ops-level on/off that does not need a rebuild.
///
/// Flags are not user settings. Settings are choices the app exposes; flags
/// are rollbacks — a way to turn a misbehaving feature off on one machine
/// (or during QA) without shipping a new build.
public enum FeatureFlag: String, CaseIterable, Sendable {
    /// The captive-portal probe after a successful association. Off means
    /// "associated" is treated as "online" without asking Apple's endpoint.
    case captivePortalDetection

    /// The session-history window and the "History…" entry point to it.
    case connectionHistory

    /// Value when neither override exists — the behaviour the app ships with.
    public var defaultValue: Bool { true }
}

/// Resolves ``FeatureFlag`` values through three layers, first match wins.
///
/// 1. **Launch argument** `-<flag> true|false`, for QA and selftests:
///    `.build/HotspotGuard.app/Contents/MacOS/HotspotGuard -captivePortalDetection false`
/// 2. **UserDefaults** key `flags.<flag>`, a per-machine ops toggle:
///    `defaults write com.example.HotspotGuard flags.captivePortalDetection -bool false`
/// 3. **Built-in default** (``FeatureFlag/defaultValue``).
/// `@unchecked Sendable` because `UserDefaults` predates conformance:
/// Apple documents it as thread-safe, and `arguments` is an immutable copy.
public struct FeatureFlags: @unchecked Sendable {
    private let defaults: UserDefaults
    private let arguments: [String]

    public init(
        defaults: UserDefaults = .standard,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        self.defaults = defaults
        self.arguments = arguments
    }

    /// Resolves a flag through the override layers down to its default.
    public func isEnabled(_ flag: FeatureFlag) -> Bool {
        let argumentIndex = arguments.firstIndex(of: "-\(flag.rawValue)")
        if let index = argumentIndex, arguments.indices.contains(index + 1) {
            return NSString(string: arguments[index + 1]).boolValue
        }
        let key = "flags.\(flag.rawValue)"
        if defaults.object(forKey: key) != nil {
            return defaults.bool(forKey: key)
        }
        return flag.defaultValue
    }
}
