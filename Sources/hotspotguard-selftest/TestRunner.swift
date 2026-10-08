import Foundation

/// Minimal assertion harness.
///
/// XCTest and swift-testing both ship inside Xcode, and this project targets a
/// Command Line Tools-only machine, so the test suite is a plain executable
/// with its own tiny runner. `swift run hotspotguard-selftest` exits non-zero
/// when anything fails, which is all CI needs.
enum TestRunner {
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) private static var currentSuite = ""

    /// Per-suite wall time, in declaration order, printed by ``report()``.
    ///
    /// A suite that suddenly doubles is a regression worth seeing even when
    /// every check inside it still passes. Measured with a monotonic clock:
    /// the wall clock can jump backwards over an NTP correction.
    nonisolated(unsafe) private static var suiteDurations: [(name: String, milliseconds: Double)] = []
    nonisolated(unsafe) private static var suiteStarted = ContinuousClock.now

    /// Optional because static storage initializes lazily.
    ///
    /// At first access — which would be report() itself — an eager default
    /// would read as 0ms. Set by the first suite instead.
    nonisolated(unsafe) private static var overallStarted: ContinuousClock.Instant?

    static func suite(_ name: String) {
        finishTiming()
        currentSuite = name
        suiteStarted = ContinuousClock.now
        if overallStarted == nil { overallStarted = suiteStarted }
        print("\n\u{1B}[1m\(name)\u{1B}[0m")
    }

    /// Closes the timing of the suite that was running, if any.
    private static func finishTiming() {
        guard !currentSuite.isEmpty else { return }
        let elapsed = suiteStarted.duration(to: ContinuousClock.now)
        let milliseconds =
            Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        suiteDurations.append((currentSuite, milliseconds))
        currentSuite = ""
    }

    /// Formats a duration compactly: `847ms` under a second, `1.2s` above.
    private static func format(milliseconds: Double) -> String {
        milliseconds < 1000
            ? "\(Int(milliseconds.rounded()))ms"
            : String(format: "%.1fs", milliseconds / 1000)
    }

    static func expect(_ condition: Bool, _ label: String) {
        if condition {
            passed += 1
            print("  \u{1B}[32m✓\u{1B}[0m \(label)")
        } else {
            let message = "\(currentSuite) › \(label)"
            failures.append(message)
            print("  \u{1B}[31m✗\u{1B}[0m \(label)")
        }
    }

    static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        if actual == expected {
            passed += 1
            print("  \u{1B}[32m✓\u{1B}[0m \(label)")
        } else {
            let message = "\(currentSuite) › \(label) — expected \(expected), got \(actual)"
            failures.append(message)
            print("  \u{1B}[31m✗\u{1B}[0m \(label) — expected \(expected), got \(actual)")
        }
    }

    static func report() -> Int32 {
        finishTiming()
        let total = (overallStarted ?? ContinuousClock.now).duration(to: ContinuousClock.now)
        let totalMilliseconds =
            Double(total.components.seconds) * 1000
            + Double(total.components.attoseconds) / 1e15

        print("\n" + String(repeating: "─", count: 52))
        for suite in suiteDurations {
            print("  \(format(milliseconds: suite.milliseconds))  \(suite.name)")
        }
        print(String(repeating: "─", count: 52))

        if failures.isEmpty {
            print(
                "\u{1B}[32m\(passed) checks passed\u{1B}[0m in \(format(milliseconds: totalMilliseconds))"
            )
            return 0
        }
        print(
            "\u{1B}[31m\(failures.count) failed\u{1B}[0m, \(passed) passed"
                + " in \(format(milliseconds: totalMilliseconds))"
        )
        for failure in failures {
            print("  • \(failure)")
        }
        return 1
    }
}
