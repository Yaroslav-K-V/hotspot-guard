import Foundation
import HotspotGuardCore

@MainActor
func main() async {
    let args = CommandLine.arguments
    let command = args.count > 1 ? args[1] : "help"
    let isJSON = args.contains("--json")

    let defaults = UserDefaults.standard
    let settings = AppSettings(defaults: defaults)
    let log = EventLog(capacity: Defaults.eventLogCapacity)

    let manager = ConnectionManager(
        settings: settings,
        log: log,
        probe: TCPConnectivityProbe(),
        wifi: CoreWLANController(),
        notifier: TerminalNotifier(),
        pathObserver: nil, // CLI doesn't need path observation for one-shot
        sleepObserver: nil,
        probeTimeout: Defaults.probeTimeout,
        postAssociationDelay: Defaults.postAssociationDelay,
        passwordProvider: { ssid in
            #if DEBUG
                if ProcessInfo.processInfo.environment["HOTSPOTGUARD_DEV_MOCK_KEYCHAIN"] == "1" {
                    return "mock_password"
                }
            #endif
            return try? KeychainHelper.password(account: ssid)
        }
    )

    switch command {
    case "status":
        await runStatus(manager: manager, isJSON: isJSON)
    case "check":
        await manager.tick()
        await runStatus(manager: manager, isJSON: isJSON)
    case "reconnect":
        await manager.reconnectNow()
        await runStatus(manager: manager, isJSON: isJSON)
    case "networks", "networks list":
        runNetworksList(settings: settings, isJSON: isJSON)
    default:
        printUsage()
    }
}

@MainActor
func runStatus(manager: ConnectionManager, isJSON: Bool) async {
    let state = manager.state
    let stateString: String
    switch state {
    case .idle: stateString = "idle"
    case .connected: stateString = "connected"
    case .reconnecting: stateString = "reconnecting"
    case .disconnected: stateString = "disconnected"
    case .captivePortal: stateString = "captivePortal"
    }

    if isJSON {
        let statusDict: [String: Any] = [
            "state": stateString,
            "currentSSID": manager.currentSSID ?? NSNull(),
            "lastLatency": manager.lastLatencyMilliseconds ?? NSNull(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: statusDict, options: .prettyPrinted),
            let string = String(data: data, encoding: .utf8)
        {
            print(string)
        }
    } else {
        print("State: \(stateString)")
        if let ssid = manager.currentSSID {
            print("Current SSID: \(ssid)")
        } else {
            print("Current SSID: None")
        }
        if let latency = manager.lastLatencyMilliseconds {
            print("Latency: \(latency)ms")
        }
    }
}

@MainActor
func runNetworksList(settings: AppSettings, isJSON: Bool) {
    let networks = settings.networks.map { $0.ssid }
    if isJSON {
        if let data = try? JSONSerialization.data(withJSONObject: networks, options: .prettyPrinted),
            let string = String(data: data, encoding: .utf8)
        {
            print(string)
        }
    } else {
        if networks.isEmpty {
            print("No networks configured.")
        } else {
            print("Configured Networks:")
            for (index, network) in networks.enumerated() {
                print("\(index + 1). \(network)")
            }
        }
    }
}

func printUsage() {
    print(
        """
        Usage: hotspotguard-cli <command> [--json]

        Commands:
          status          Shows the current state of the connection
          check           Forces a single tick/check of the connection
          reconnect       Forces a reconnect attempt
          networks list   Lists the currently configured network SSIDs
        """)
}

struct TerminalNotifier: NotificationPresenter {
    func requestAuthorization() async {}
    func present(title: String, body: String) async {
        print("\n[NOTIFICATION] \(title)")
        print("\(body)\n")
    }
}

await main()
