import Foundation

/// Runs the MCP server: the loopback listener, the HTTP gate on its queue,
/// and the hop to the main actor for everything that touches the app.
@MainActor
public final class MCPService {
    public enum Status: Equatable, Sendable {
        case off
        case starting
        case listening(port: Int)
        case failed(LoopbackHTTPServer.Failure)
    }

    public private(set) var status = Status.off {
        didSet { if status != oldValue { statusChanged(status) } }
    }
    public var statusChanged: (Status) -> Void = { _ in }

    public let counters: MCPTrafficCounters
    private let server: MCPServer
    private let limiter: RateLimiter
    private let endpointFile: MCPEndpointFile?
    private var listener: LoopbackHTTPServer?
    private var requestedPort = 0
    private var retried = false
    private var generation = 0
    private let boundPort = BoundPort()

    public init(server: MCPServer, limiter: RateLimiter, counters: MCPTrafficCounters,
                endpointFile: MCPEndpointFile?) {
        self.server = server
        self.limiter = limiter
        self.counters = counters
        self.endpointFile = endpointFile
    }

    /// Starts listening on `port` (0 picks a free one, for tests), replacing
    /// any listener already running.
    public func start(port: Int) {
        stopListener()
        requestedPort = port
        retried = false
        listen()
    }

    public func stop() {
        stopListener()
        status = .off
    }

    private func listen() {
        generation += 1
        let current = generation
        let gate = makeHandler()
        let configuration = server.configuration
        let listener = LoopbackHTTPServer(port: requestedPort, limits: configuration.http,
                                          maxConnections: configuration.maxConnections, handler: gate)
        self.listener = listener
        status = .starting
        listener.start { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.listenerChanged(state)
            }
        }
    }

    private func listenerChanged(_ state: LoopbackHTTPServer.State) {
        switch state {
        case .stopped, .starting: break
        case .ready(let port):
            boundPort.value = port
            endpointFile?.write(port: port)
            status = .listening(port: port)
        case .failed(let failure):
            let wasListening = if case .listening = status { true } else { false }
            stopListener()
            // A listener that dies at runtime gets one restart; a port that's
            // taken never does (agent configs embed the URL, so never move it).
            if wasListening, !retried, failure != .portInUse(requestedPort) {
                retried = true
                status = .starting
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let self, self.status == .starting, self.listener == nil else { return }
                    self.listen()
                }
            } else {
                status = .failed(failure)
            }
        }
    }

    private func stopListener() {
        generation += 1
        listener?.stop()
        listener = nil
        boundPort.value = 0
        endpointFile?.remove()
    }

    /// The handler runs on the HTTP queue. Requests that fail the gate are
    /// answered there; the rest hop to the main actor.
    private func makeHandler() -> LoopbackHTTPServer.Handler {
        let port = boundPort
        let configuration = server.configuration
        let limiter = limiter
        let counters = counters
        let server = UncheckedBox(server)
        return { request, connection, reply in
            let send: @Sendable (HTTPResponse, Bool) -> Void = { response, close in
                counters.record(status: response.status)
                reply(response, close)
            }
            let key: String
            switch MCPHTTPGate.check(request, port: port.value, configuration: configuration) {
            case .respond(let response, let close):
                send(response, close)
                return
            case .unauthenticated:
                // Under lockout, refuse without touching the main actor.
                if let wait = limiter.authLockout() {
                    counters.recordAuthFailure()
                    send(MCPHTTPGate.lockedOut(retryAfter: wait), true)
                    return
                }
                key = ""
            case .proceed(let presented):
                key = presented
            }
            // A Task rather than DispatchQueue.main: hosts that drain the main
            // queue with dispatchMain() run it off the main thread.
            Task { @MainActor in
                server.value.handle(request, key: key, whenClosed: { action in
                    let action = UncheckedBox(action)
                    return connection.whenClosed {
                        Task { @MainActor in action.value() }
                    }
                }, reply: { send($0.response, $0.close) })
            }
        }
    }
}

/// The port the listener actually bound, read by the gate on the HTTP queue.
private final class BoundPort: @unchecked Sendable {
    private let lock = NSLock()
    private var port = 0

    var value: Int {
        get { lock.lock(); defer { lock.unlock() }; return port }
        set { lock.lock(); port = newValue; lock.unlock() }
    }
}

/// Carries a main-actor value across a queue hop that ends on the main actor.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
