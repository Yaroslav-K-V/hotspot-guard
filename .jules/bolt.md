## 2024-05-24 - URLSession Creation Overhead
**Learning:** Instantiating `URLSession(configuration:)` for every network probe is an expensive operation that wastes CPU cycles and memory. In Swift/iOS/macOS development, it is a known anti-pattern to recreate `URLSession` for frequent, repeated requests instead of reusing a single instance.
**Action:** Always share a single `URLSession` for repeated tasks to improve performance and reduce resource allocation overhead. Reusing `URLSession` is officially recommended by Apple.

## 2024-05-25 - Avoid Thread.sleep in Swift concurrency and GCD
**Learning:** Using `Thread.sleep` inside a Grand Central Dispatch (GCD) queue block or a Swift concurrency task blocks the underlying thread. If used inside a serial queue, it stalls the entire queue and any other operations dispatched to it.
**Action:** Always replace `Thread.sleep` with `try await Task.sleep` in async contexts to yield the thread rather than blocking it, preserving queue and thread pool responsiveness.
