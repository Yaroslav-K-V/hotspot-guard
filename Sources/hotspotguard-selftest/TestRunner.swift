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

    static func suite(_ name: String) {
        currentSuite = name
        print("\n\u{1B}[1m\(name)\u{1B}[0m")
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
        print("\n" + String(repeating: "─", count: 52))
        if failures.isEmpty {
            print("\u{1B}[32m\(passed) checks passed\u{1B}[0m")
            return 0
        }
        print("\u{1B}[31m\(failures.count) failed\u{1B}[0m, \(passed) passed")
        for failure in failures {
            print("  • \(failure)")
        }
        return 1
    }
}
