import CoreLocation
import Foundation

/// Requests the Location permission that CoreWLAN requires.
///
/// Why a Wi-Fi utility asks for your location, in short: the set of Wi-Fi
/// networks around you identifies where you are with street-level accuracy —
/// that is how Apple's own location database works. So since macOS Sonoma the
/// system gates the APIs that expose nearby-network information behind Location
/// Services. Concretely, without authorization:
///
///   * `CWInterface.ssid()` returns `nil` even while connected, and
///   * `CWInterface.scanForNetworks` fails with a "not permitted" error.
///
/// The app never reads your coordinates. It requests the permission solely so
/// CoreWLAN will answer, which is what `NSLocationUsageDescription` in
/// Info.plist tells the user.
@MainActor
public protocol LocationManagerProtocol: AnyObject {
    var delegate: CLLocationManagerDelegate? { get set }
    var authStatus: CLAuthorizationStatus { get }
    func requestWhenInUseAuthorization()
}

extension CLLocationManager: LocationManagerProtocol {
    public var authStatus: CLAuthorizationStatus {
        if #available(macOS 11.0, *) {
            return self.authorizationStatus
        } else {
            return CLLocationManager.authorizationStatus()
        }
    }
}

@MainActor
public final class LocationAuthorization: NSObject, CLLocationManagerDelegate {
    private let manager: any LocationManagerProtocol
    private var onChange: (@MainActor (CLAuthorizationStatus) -> Void)?

    public var status: CLAuthorizationStatus {
        manager.authStatus
    }

    /// `true` when CoreWLAN will return real data.
    public var isAuthorized: Bool {
        switch status {
        case .authorized, .authorizedAlways:
            return true
        default:
            return false
        }
    }

    public init(manager: any LocationManagerProtocol) {
        self.manager = manager
        super.init()
        self.manager.delegate = self
    }

    public override convenience init() {
        self.init(manager: CLLocationManager())
    }

    /// Prompts if the user has not decided yet.
    ///
    /// A no-op once decided — re-requesting after a denial does nothing, by
    /// design of the system.
    public func request(onChange: (@MainActor (CLAuthorizationStatus) -> Void)? = nil) {
        self.onChange = onChange
        guard status == .notDetermined else {
            onChange?(status)
            return
        }
        manager.requestWhenInUseAuthorization()
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.onChange?(status)
        }
    }
}
