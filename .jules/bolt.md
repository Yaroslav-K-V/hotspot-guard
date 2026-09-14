## 2024-05-24 - URLSession Creation Overhead
**Learning:** Instantiating `URLSession(configuration:)` for every network probe is an expensive operation that wastes CPU cycles and memory. In Swift/iOS/macOS development, it is a known anti-pattern to recreate `URLSession` for frequent, repeated requests instead of reusing a single instance.
**Action:** Always share a single `URLSession` for repeated tasks to improve performance and reduce resource allocation overhead. Reusing `URLSession` is officially recommended by Apple.
