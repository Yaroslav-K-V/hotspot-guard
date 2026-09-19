## 2024-11-20 - Added tooltips to reorder buttons in HotspotGuard

**Learning:** SwiftUI `.help` modifier is the primary way to add tooltips and improve accessibility for icon-only buttons. Many existing controls like the "remove network" button already had these, but purely structural buttons like move up/down had been missed.
**Action:** Always check icon-only buttons (`Image(systemName:)` wrapped in `Button`) for `.help()` modifiers when working with SwiftUI files to ensure standard tooltip behavior and basic accessibility.
