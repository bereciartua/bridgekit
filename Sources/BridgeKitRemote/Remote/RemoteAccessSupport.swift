import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// "Keep this Mac awake while on power": an idle-sleep assertion held only
/// while Remote Access is on and the Mac runs on AC power. Closing the lid
/// still sleeps the Mac unless an external display is attached.
@MainActor
public final class KeepAwake {
    private let reason: String
    private var assertion: IOPMAssertionID = 0
    private var held = false

    /// `reason` shows in `pmset -g assertions` ("Funes Vault Remote Access is on").
    public init(reason: String) {
        self.reason = reason
    }

    public func set(_ on: Bool) {
        if on && !held {
            held = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                               IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString,
                                               &assertion) == kIOReturnSuccess
        } else if !on && held {
            IOPMAssertionRelease(assertion)
            held = false
        }
    }

    public static var onACPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }
}

/// A reachability test that didn't reach this app. Each app words it.
public enum RemoteProbeFailure: Error, Equatable, Sendable {
    /// No public address saved yet.
    case noAddress
    case invalidAddress
    /// No answer within 10 seconds.
    case timedOut
    /// The name doesn't resolve (yet: new Funnel names take minutes).
    case cannotFindHost
    case connectionRefused
    case certificateRejected
    /// Another `URLError`, by code.
    case requestFailed(code: Int)
    /// 421: the tunnel sent a Host that isn't the saved address.
    case wrongHost
    /// Something answered, but not this app (or not with its nonce).
    case notThisApp(status: Int)
    case noAnswer
}

public struct RemoteProbeResult: Equatable, Sendable {
    public let rtt: TimeInterval
    /// The tunnel the health route saw, from its headers.
    public let tunnel: TunnelProvider?

    public init(rtt: TimeInterval, tunnel: TunnelProvider?) {
        self.rtt = rtt
        self.tunnel = tunnel
    }
}

/// The Remote Access page ▸ Test: one HTTPS request to this app's own health
/// URL through the tunnel. The nonce proves the reply came from this app, not
/// from something else answering at that address.
public enum RemoteProbe {
    @MainActor
    public static func test(_ configuration: RemoteConfiguration, nonces: RemoteNonces,
                            completion: @escaping @MainActor @Sendable (Result<RemoteProbeResult, RemoteProbeFailure>) -> Void) {
        guard let origin = configuration.publicOrigin else { return completion(.failure(.noAddress)) }
        let nonce = nonces.issue()
        guard let url = URL(string: origin + configuration.secretPrefix + "/health?nonce=" + nonce) else {
            return completion(.failure(.invalidAddress))
        }
        let session = URLSession(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 15
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieStorage = nil
            return configuration
        }(), delegate: NoRedirects(), delegateQueue: nil)
        let started = Date()
        session.dataTask(with: url) { data, response, error in
            let rtt = Date().timeIntervalSince(started)
            let result = Self.result(data: data, response: response, error: error, nonce: nonce, rtt: rtt)
            session.finishTasksAndInvalidate()
            Task { @MainActor in completion(result) }
        }.resume()
    }

    static func result(data: Data?, response: URLResponse?, error: Error?, nonce: String,
                       rtt: TimeInterval) -> Result<RemoteProbeResult, RemoteProbeFailure> {
        if let error = error as? URLError { return .failure(failure(error)) }
        if let http = response as? HTTPURLResponse, http.statusCode == 200, let data,
           let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           body["nonce"] as? String == nonce {
            return .success(RemoteProbeResult(rtt: rtt, tunnel: TunnelProvider(wireName: body["tunnel"] as? String)))
        }
        if let http = response as? HTTPURLResponse {
            return .failure(http.statusCode == 421 ? .wrongHost : .notThisApp(status: http.statusCode))
        }
        return .failure(.noAnswer)
    }

    static func failure(_ error: URLError) -> RemoteProbeFailure {
        switch error.code {
        case .timedOut: .timedOut
        case .cannotFindHost, .dnsLookupFailed: .cannotFindHost
        case .cannotConnectToHost: .connectionRefused
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate: .certificateRejected
        default: .requestFailed(code: error.code.rawValue)
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
