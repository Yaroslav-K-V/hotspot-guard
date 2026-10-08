import AppKit
import HotspotGuardCore

/// Builds the coloured menu bar glyph.
///
/// The image is explicitly *not* a template image: template images are recoloured
/// by the system to match the menu bar, which would throw away the green/yellow/red
/// signal that is the whole point of the icon.
enum StatusIcon {
    static func image(for state: ConnectionManager.State) -> NSImage {
        let symbol = symbolName(for: state)
        let color = color(for: state)

        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))

        let configured = NSImage(systemSymbolName: symbol, accessibilityDescription: label(for: state))?
            .withSymbolConfiguration(configuration)
        if let image = configured {
            image.isTemplate = false
            return image
        }

        return fallbackDot(color: color)
    }

    static func label(for state: ConnectionManager.State) -> String {
        switch state {
        case .idle: return "Monitoring off"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting"
        case .disconnected: return "Disconnected"
        case .captivePortal: return "Sign-in required"
        }
    }

    static func color(for state: ConnectionManager.State) -> NSColor {
        switch state {
        case .idle: return .secondaryLabelColor
        case .connected: return .systemGreen
        case .reconnecting: return .systemYellow
        // Blue, not red: traffic is not flowing, but nothing is broken and
        // there is a clear action to take. Red would say "reconnect", which is
        // the one thing that would make it worse.
        case .captivePortal: return .systemBlue
        case .disconnected: return .systemRed
        }
    }

    private static func symbolName(for state: ConnectionManager.State) -> String {
        switch state {
        case .idle: return "wifi"
        case .connected: return "wifi"
        case .reconnecting: return "wifi.exclamationmark"
        case .captivePortal: return "person.badge.key"
        case .disconnected: return "wifi.slash"
        }
    }

    /// Plain coloured dot, in case a future macOS renames one of the symbols.
    private static func fallbackDot(color: NSColor) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
