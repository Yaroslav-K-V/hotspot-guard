## 2024-05-24 - URLSession Creation Overhead
**Learning:** Instantiating `URLSession(configuration:)` for every network probe is an expensive operation that wastes CPU cycles and memory. In Swift/iOS/macOS development, it is a known anti-pattern to recreate `URLSession` for frequent, repeated requests instead of reusing a single instance.
**Action:** Always share a single `URLSession` for repeated tasks to improve performance and reduce resource allocation overhead. Reusing `URLSession` is officially recommended by Apple.

## 2024-05-25 - Avoid Thread.sleep in Swift concurrency and GCD
**Learning:** Using `Thread.sleep` inside a Grand Central Dispatch (GCD) queue block or a Swift concurrency task blocks the underlying thread. If used inside a serial queue, it stalls the entire queue and any other operations dispatched to it.
**Action:** Always replace `Thread.sleep` with `try await Task.sleep` in async contexts to yield the thread rather than blocking it, preserving queue and thread pool responsiveness.

## 2024-05-27 - N+1 Keychain Lookups
**Learning:** Performing repeated lookups (like `SecItemCopyMatching`) for individual items inside a loop over all items is a classic N+1 query problem, causing significant CPU and I/O overhead.
**Action:** When working with the Keychain or similar storage, fetch all required data at once in a single bulk query (e.g., using `kSecReturnData: true`) if possible, instead of querying item-by-item.

## 2024-09-14 - Protocol Conformance with OS Constraints
**Learning:** When creating a mockable protocol for an Apple framework class like `CLLocationManager` that has availability restrictions on some properties (like `authorizationStatus` becoming an instance property only on macOS 11.0+), simply declaring the same property name on the protocol will break compilation on older deployment targets.
**Action:** Define a custom property name (e.g., `authStatus`) on the protocol, and in the framework class extension, implement that custom property by wrapping the OS-specific availability checks (`if #available(...)`) internally. This ensures the protocol is universally satisfiable across all supported deployment targets.
