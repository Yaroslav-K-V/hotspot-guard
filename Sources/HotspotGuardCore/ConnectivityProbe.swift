import Foundation
import Network

/// Answers one question: can this machine actually reach the internet?
///
/// A protocol rather than a concrete type so ``ConnectionManager`` can be
/// exercised against a fake that reports "offline" on demand — testing the
/// reconnection logic otherwise requires physically dropping Wi-Fi.
public protocol ConnectivityProbe: Sendable {
    /// Measures reachability, latency and captive-portal interception.
    func check(timeout: TimeInterval) async -> ConnectivityResult
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

/// Detects whether HTTP is being intercepted by a login portal.
public protocol CaptivePortalDetector: Sendable {
    func isIntercepted(timeout: TimeInterval) async -> Bool
}

/// Reachability via a plain TCP handshake, using Network.framework.
///
/// Chosen over ICMP echo deliberately. A real `ping` needs raw sockets and a
/// hand-rolled ICMP packet, and it also answers the wrong question: a captive
/// portal will happily route ICMP while blocking everything else, so ping says
/// "online" on exactly the network where you are not. Completing a TCP
/// handshake to an off-network host is a stronger signal and needs no
/// privileges.
///
/// The TCP handshake alone still cannot see a portal that lets connections
/// through and rewrites HTTP, so a successful handshake is followed by a
/// ``CaptivePortalDetector`` check.
public struct TCPConnectivityProbe: ConnectivityProbe {
    private let endpoints: [ProbeEndpoint]
    private let portalDetector: CaptivePortalDetector?

    public init(
        endpoints: [ProbeEndpoint] = ProbeEndpoint.defaults,
        portalDetector: CaptivePortalDetector? = AppleCaptivePortalDetector()
    ) {
        self.endpoints = endpoints
        self.portalDetector = portalDetector
    }

    public func check(timeout: TimeInterval = Defaults.probeTimeout) async -> ConnectivityResult {
        guard !endpoints.isEmpty else { return .offline }

        // Race the endpoints: the first success wins and cancels the rest, so
        // total latency is bounded by `timeout` rather than by their sum.
        let tcp: ConnectivityResult = await withTaskGroup(of: ConnectivityResult.self) { group in
            for endpoint in endpoints {
                group.addTask { await Self.connect(to: endpoint, timeout: timeout) }
            }
            for await result in group where result.status == .online {
                group.cancelAll()
                return result
            }
            return .offline
        }

        guard tcp.status == .online else { return .offline }
        guard let portalDetector else { return tcp }

        // Only worth asking once TCP works: with no route at all, the portal
        // check would just burn another timeout confirming what we know.
        if await portalDetector.isIntercepted(timeout: timeout) {
            return ConnectivityResult(
                status: .captivePortal,
                latency: tcp.latency,
                respondingHost: tcp.respondingHost
            )
        }
        return tcp
    }

    private static func connect(
        to endpoint: ProbeEndpoint,
        timeout: TimeInterval
    ) async -> ConnectivityResult {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { return .offline }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = max(1, Int(timeout.rounded(.up)))
        tcpOptions.noDelay = true

        let connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: port,
            using: NWParameters(tls: nil, tcp: tcpOptions)
        )
        let queue = DispatchQueue(label: "com.yaroslavkv.hotspotguard.probe.\(endpoint.host)")

        // Measured with a monotonic clock: the wall clock can jump backwards
        // over an NTP correction and produce a negative latency.
        let started = ContinuousClock.now

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ConnectivityResult, Never>) in
                let resumer = SingleResume(continuation) { connection.cancel() }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        resumer.finish(ConnectivityResult(
                            status: .online,
                            latency: started.duration(to: ContinuousClock.now),
                            respondingHost: endpoint.host
                        ))
                    case .failed, .cancelled:
                        resumer.finish(.offline)
                    case .waiting:
                        // `.waiting` means there is no usable route — with no
                        // Wi-Fi association this is where a connection parks
                        // indefinitely. Treat it as offline immediately
                        // instead of burning the whole timeout.
                        resumer.finish(.offline)
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
                    resumer.finish(.offline)
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

/// Uses Apple's own captive-portal endpoint — the one macOS itself probes.
///
/// It returns a tiny, fixed document. Anything else (a redirect, a login page,
/// an error) means something is sitting between this Mac and the internet.
public struct AppleCaptivePortalDetector: CaptivePortalDetector {
    private static let url = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    private static let expectedBody = "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"

    public init() {}

    public func isIntercepted(timeout: TimeInterval) async -> Bool {
        var request = URLRequest(url: Self.url)
        request.timeoutInterval = timeout
        // Must not be served from cache: a cached "Success" from the previous
        // network would hide the portal we are looking for.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.allowsCellularAccess = true
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(for: request)

            // A portal usually redirects; anything but 200 is interception.
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return true
            }

            let body = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return body != Self.expectedBody
        } catch {
            // The request failing is not evidence of a portal — it looks the
            // same as the connection dying between the TCP check and now.
            // Reporting "portal" here would suppress a genuine reconnect.
            return false
        }
    }
}

/// Guarantees a `CheckedContinuation` is resumed exactly once.
///
/// Both the state handler and the timeout backstop can fire, and resuming a
/// continuation twice traps. The lock makes the first caller the only caller.
private final class SingleResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ConnectivityResult, Never>?
    private let cleanup: @Sendable () -> Void

    init(
        _ continuation: CheckedContinuation<ConnectivityResult, Never>,
        cleanup: @escaping @Sendable () -> Void
    ) {
        self.continuation = continuation
        self.cleanup = cleanup
    }

    func finish(_ value: ConnectivityResult) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()

        guard let pending else { return }
        pending.resume(returning: value)
        cleanup()
    }
}
