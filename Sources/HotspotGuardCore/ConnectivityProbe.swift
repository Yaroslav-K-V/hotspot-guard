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

    /// Cloudflare DNS over TLS and Google DNS.
    ///
    /// Two providers so one operator having a bad day does not read as "the
    /// internet is down".
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
    /// One connection attempt against an endpoint.
    ///
    /// Injectable because "the network is down" cannot be faked reliably from
    /// a test: even TEST-NET-1 (RFC 5737) answers when a VPN or transparent
    /// proxy intercepts all connections. Tests pass a connector that reports
    /// offline on demand instead of depending on the machine's network.
    public typealias Connector = @Sendable (ProbeEndpoint, TimeInterval) async -> ConnectivityResult

    /// Second opinion when every TCP handshake fails.
    ///
    /// Injectable for the same reason as ``Connector``: the real check hits
    /// the network, so tests stub it instead of depending on the machine
    /// being offline.
    public typealias FallbackCheck = @Sendable (TimeInterval) async -> ConnectivityResult

    private let endpoints: [ProbeEndpoint]
    private let portalDetector: CaptivePortalDetector?
    private let connector: Connector
    private let fallback: FallbackCheck

    public init(
        endpoints: [ProbeEndpoint] = ProbeEndpoint.defaults,
        portalDetector: CaptivePortalDetector? = AppleCaptivePortalDetector(),
        connector: Connector? = nil,
        fallback: FallbackCheck? = nil
    ) {
        self.endpoints = endpoints
        self.portalDetector = portalDetector
        // Wrapped in a @Sendable closure: a bare function reference is not
        // @Sendable, and the task group hops domains with it.
        self.connector =
            connector ?? { @Sendable endpoint, timeout in
                await Self.connect(to: endpoint, timeout: timeout)
            }
        self.fallback =
            fallback ?? { @Sendable timeout in
                await Self.fallbackHTTPCheck(timeout: timeout)
            }
    }

    public func check(timeout: TimeInterval = Defaults.probeTimeout) async -> ConnectivityResult {
        guard !endpoints.isEmpty else { return .offline }

        let connector = connector
        // Race the endpoints: the first success wins and cancels the rest, so
        // total latency is bounded by `timeout` rather than by their sum.
        let tcp: ConnectivityResult = await withTaskGroup(of: ConnectivityResult.self) { group in
            for endpoint in endpoints {
                group.addTask { await connector(endpoint, timeout) }
            }
            for await result in group where result.status == .online {
                group.cancelAll()
                return result
            }
            return .offline
        }

        var finalResult = tcp
        if finalResult.status == .offline {
            finalResult = await fallback(timeout)
        }
        if finalResult.status == .captivePortal {
            return finalResult
        }
        guard finalResult.status == .online else { return .offline }
        guard let portalDetector else { return finalResult }

        // Only worth asking once TCP works: with no route at all, the portal
        // check would just burn another timeout confirming what we know.
        if await portalDetector.isIntercepted(timeout: timeout) {
            return ConnectivityResult(
                status: .captivePortal,
                latency: finalResult.latency,
                respondingHost: finalResult.respondingHost
            )
        }
        return finalResult
    }

    private static func makeTCPConnection(host: String, port: NWEndpoint.Port, timeout: TimeInterval) -> NWConnection {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = max(1, Int(timeout.rounded(.up)))
        tcpOptions.noDelay = true

        return NWConnection(
            host: NWEndpoint.Host(host),
            port: port,
            using: NWParameters(tls: nil, tcp: tcpOptions)
        )
    }

    private static func connect(
        to endpoint: ProbeEndpoint,
        timeout: TimeInterval
    ) async -> ConnectivityResult {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { return .offline }

        let connection = makeTCPConnection(host: endpoint.host, port: port, timeout: timeout)
        let queue = DispatchQueue(label: "com.yaroslavkv.hotspotguard.probe.\(endpoint.host)", qos: .utility)

        // Measured with a monotonic clock: the wall clock can jump backwards
        // over an NTP correction and produce a negative latency.
        let started = ContinuousClock.now

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ConnectivityResult, Never>) in
                let resumer = SingleResume(continuation) { connection.cancel() }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        resumer.finish(
                            ConnectivityResult(
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

    /// Lightweight HTTP fallback via `NWConnection` directly, avoiding `URLSession` overhead.
    ///
    /// Checks Apple's standard captive portal endpoint. Validates HTTP 200 and the presence
    /// of the word "Success" in the body payload. Used strictly when primary TCP checks fail.
    private static func fallbackHTTPCheck(timeout: TimeInterval) async -> ConnectivityResult {
        let host = "captive.apple.com"
        let port = NWEndpoint.Port(rawValue: 80)!

        let connection = makeTCPConnection(host: host, port: port, timeout: timeout)
        let queue = DispatchQueue(label: "com.yaroslavkv.hotspotguard.probe.httpfallback", qos: .utility)

        let started = ContinuousClock.now

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ConnectivityResult, Never>) in
                let resumer = SingleResume(continuation) { connection.cancel() }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let requestString =
                            "GET /hotspot-detect.html HTTP/1.1\r\nHost: captive.apple.com\r\nConnection: close\r\n\r\n"
                        let data = requestString.data(using: .utf8)!

                        connection.send(
                            content: data,
                            completion: .contentProcessed({ error in
                                if error != nil {
                                    resumer.finish(.offline)
                                } else {
                                    // To avoid recursive capturing and mutating local vars inside escaping closures,
                                    // we define a dedicated actor or class state. However, since the payload is usually tiny
                                    // and single-chunk, we can just do one large read. Apple's captive payload is very small.
                                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                                        content, _, _, error in
                                        if error != nil {
                                            resumer.finish(.offline)
                                            return
                                        }
                                        guard let content = content,
                                            let responseStr = String(data: content, encoding: .utf8)
                                        else {
                                            resumer.finish(.offline)
                                            return
                                        }
                                        let is200OK = responseStr.contains("200 OK") || responseStr.contains("200 ok")
                                        let containsSuccess = responseStr.localizedCaseInsensitiveContains("Success")
                                        if is200OK && containsSuccess {
                                            resumer.finish(
                                                ConnectivityResult(
                                                    status: .online,
                                                    latency: started.duration(to: ContinuousClock.now),
                                                    respondingHost: host
                                                ))
                                        } else {
                                            resumer.finish(
                                                ConnectivityResult(
                                                    status: .captivePortal,
                                                    latency: started.duration(to: ContinuousClock.now),
                                                    respondingHost: host
                                                ))
                                        }
                                    }
                                }
                            }))
                    case .failed, .cancelled, .waiting:
                        resumer.finish(.offline)
                    case .setup, .preparing:
                        break
                    @unknown default:
                        break
                    }
                }

                connection.start(queue: queue)

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

    private static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.allowsCellularAccess = true
        return URLSession(configuration: configuration)
    }()

    public func isIntercepted(timeout: TimeInterval) async -> Bool {
        var request = URLRequest(url: Self.url)
        request.timeoutInterval = timeout
        // Must not be served from cache: a cached "Success" from the previous
        // network would hide the portal we are looking for.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (data, response) = try await Self.sharedSession.data(for: request)

            // A portal usually redirects; anything but 200 is interception.
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return true
            }

            let body = (String(bytes: data, encoding: .utf8) ?? "")
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
