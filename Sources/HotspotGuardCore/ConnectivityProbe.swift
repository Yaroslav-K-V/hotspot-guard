import Foundation
import Network

/// Answers one question: can this machine actually reach the internet?
///
/// A protocol rather than a concrete type so ``ConnectionManager`` can be
/// exercised against a fake that reports "offline" on demand — testing the
/// reconnection logic otherwise requires physically dropping Wi-Fi.
public protocol ConnectivityProbe: Sendable {
    /// Returns `true` if any probe endpoint answered within `timeout`.
    func check(timeout: TimeInterval) async -> Bool
}

/// A TCP endpoint used as a reachability target.
public struct ProbeEndpoint: Sendable, Equatable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// Cloudflare DNS over TLS and Google DNS. Two providers so one operator
    /// having a bad day does not read as "the internet is down".
    public static let defaults: [ProbeEndpoint] = [
        ProbeEndpoint(host: "1.1.1.1", port: 443),
        ProbeEndpoint(host: "8.8.8.8", port: 53),
    ]
}

/// Reachability via a plain TCP handshake, using Network.framework.
///
/// Chosen over ICMP echo deliberately. A real `ping` needs raw sockets and a
/// hand-rolled ICMP packet, and it also answers the wrong question: a captive
/// portal will happily route ICMP while blocking everything else, so ping says
/// "online" on exactly the network where you are not. Completing a TCP
/// handshake to an off-network host is a stronger signal and needs no
/// privileges.
public struct TCPConnectivityProbe: ConnectivityProbe {
    private let endpoints: [ProbeEndpoint]

    public init(endpoints: [ProbeEndpoint] = ProbeEndpoint.defaults) {
        self.endpoints = endpoints
    }

    public func check(timeout: TimeInterval = 2) async -> Bool {
        guard !endpoints.isEmpty else { return false }

        // Race the endpoints: the first success wins and cancels the rest, so
        // total latency is bounded by `timeout` rather than by their sum.
        return await withTaskGroup(of: Bool.self) { group in
            for endpoint in endpoints {
                group.addTask { await Self.connect(to: endpoint, timeout: timeout) }
            }
            for await reachable in group where reachable {
                group.cancelAll()
                return true
            }
            return false
        }
    }

    private static func connect(to endpoint: ProbeEndpoint, timeout: TimeInterval) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { return false }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = max(1, Int(timeout.rounded(.up)))
        tcpOptions.noDelay = true

        let connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: port,
            using: NWParameters(tls: nil, tcp: tcpOptions)
        )
        let queue = DispatchQueue(label: "com.yaroslavkv.hotspotguard.probe.\(endpoint.host)")

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let resumer = SingleResume(continuation) { connection.cancel() }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        resumer.finish(true)
                    case .failed, .cancelled:
                        resumer.finish(false)
                    case .waiting:
                        // `.waiting` means there is no usable route — with no
                        // Wi-Fi association this is where a connection parks
                        // indefinitely. Treat it as offline immediately
                        // instead of burning the whole timeout.
                        resumer.finish(false)
                    case .setup, .preparing:
                        break
                    @unknown default:
                        break
                    }
                }

                connection.start(queue: queue)

                // Backstop: `connectionTimeout` covers the handshake, but not
                // every path through Network.framework reports a state change.
                queue.asyncAfter(deadline: .now() + timeout + 0.5) {
                    resumer.finish(false)
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

/// Guarantees a `CheckedContinuation` is resumed exactly once.
///
/// Both the state handler and the timeout backstop can fire, and resuming a
/// continuation twice traps. The lock makes the first caller the only caller.
private final class SingleResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private let cleanup: @Sendable () -> Void

    init(_ continuation: CheckedContinuation<Bool, Never>, cleanup: @escaping @Sendable () -> Void) {
        self.continuation = continuation
        self.cleanup = cleanup
    }

    func finish(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()

        guard let pending else { return }
        pending.resume(returning: value)
        cleanup()
    }
}
