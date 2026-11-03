import Foundation

/// Where an open is recorded. Must match the server: `production` opens only
/// redeem production clicks; `sandbox`/`test` opens only redeem `?pt_test=1`
/// clicks and only join RevenueCat SANDBOX purchases.
public enum PulseEnvironment: String, Codable, Sendable {
    case production, sandbox, test
}

/// Device signals the server's estimated matcher reads (`open-api.ts`
/// `sanitizeSignals`). Unknown keys are dropped server-side, so nothing else
/// is sent.
struct Signals: Codable, Equatable {
    var os_version: String?
    var languages: [String]?
    var timezone: String?
    var screen_pts: [Double]?
    var scale: Double?
}

/// Exact body of `POST /v1/app/open`.
struct OpenBody: Codable, Equatable {
    var open_id: String
    var environment: String
    var app_user_id: String?
    var clipboard_token: String?
    var install_referrer: String?
    var signals: Signals
}

/// Clipboard content PulseTracker may upload: only its own handoff link
/// (`…/h/<token>`) or a bare `pt1_<token>`. Anything else never leaves the device.
enum Handoff {
    private static let tokenChars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")

    /// Returns `pt1_<token>` — only the token is ever uploaded, never the copied text.
    /// Accepted shapes: `pt1_<token>` or exactly `https://<host>/h/<token>` with no
    /// credentials, query or fragment (the host may be a customer's own link domain).
    static func token(in raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count <= 512 else { return nil }
        if s.hasPrefix("pt1_") {
            let t = String(s.dropFirst(4))
            return valid(t) ? "pt1_" + t : nil
        }
        guard let c = URLComponents(string: s), c.scheme == "https", c.host?.isEmpty == false,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              let url = c.url, url.pathComponents.count == 3,
              url.pathComponents[0] == "/", url.pathComponents[1] == "h" else { return nil }
        let t = url.pathComponents[2]
        return valid(t) ? "pt1_" + t : nil
    }

    private static func valid(_ t: String) -> Bool {
        (10...128).contains(t.count) && t.unicodeScalars.allSatisfy { tokenChars.contains($0) }
    }
}

/// What the server said, reduced to what the retry loop needs.
enum SendOutcome: Equatable {
    case done          // 2xx (recorded or tracking_paused) or 400/401 (fix the call, never retry)
    case retry(after: TimeInterval?)  // 429 (Retry-After) / 5xx / network
}

func outcome(status: Int, retryAfter: String?) -> SendOutcome {
    if (200..<300).contains(status) || status == 400 || status == 401 { return .done }
    if status == 429, let s = retryAfter, let secs = Double(s), secs > 0 { return .retry(after: min(secs, 3600)) }
    return .retry(after: nil)
}

/// 1 s doubling to a 1 h cap; the whole report gives up 24 h after the first attempt.
struct Backoff {
    static let first: TimeInterval = 1
    static let cap: TimeInterval = 3600
    static let deadline: TimeInterval = 24 * 3600
    static func next(_ d: TimeInterval) -> TimeInterval { min(d * 2, cap) }
}

/// Install-scoped state in UserDefaults (NOT the Keychain: a reinstall must
/// get a fresh open_id so the server can tell reinstalls apart).
final class Store {
    private let d: UserDefaults
    init(_ d: UserDefaults = .standard) { self.d = d }

    var openId: String {
        if let s = d.string(forKey: "pt_open_id") { return s }
        let s = UUID().uuidString.lowercased()
        d.set(s, forKey: "pt_open_id")
        return s
    }
    /// Pending body survives app kills so retries resume on the next launch.
    var pending: OpenBody? {
        get { d.data(forKey: "pt_pending").flatMap { try? JSONDecoder().decode(OpenBody.self, from: $0) } }
        set { d.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "pt_pending") }
    }
    var firstAttemptAt: Date? {
        get { d.object(forKey: "pt_first_attempt") as? Date }
        set { d.set(newValue, forKey: "pt_first_attempt") }
    }
    /// The first open (with its one-time clipboard read) has been prepared.
    var reported: Bool {
        get { d.bool(forKey: "pt_reported") }
        set { d.set(newValue, forKey: "pt_reported") }
    }
    var sentUserId: String? {
        get { d.string(forKey: "pt_sent_user") }
        set { d.set(newValue, forKey: "pt_sent_user") }
    }
}

/// Sends one body with the server's retry rules. `sleep` is injectable for tests.
struct Sender {
    var apiBase: URL
    var appKey: String
    var session: URLSession = .shared
    var sleep: (TimeInterval) async -> Void = { s in try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
    var now: () -> Date = Date.init

    func request(_ body: OpenBody) throws -> URLRequest {
        var req = URLRequest(url: apiBase.appendingPathComponent("v1/app/open"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(appKey, forHTTPHeaderField: "X-PT-App-Key")
        req.httpBody = try JSONEncoder().encode(body)
        return req
    }

    /// Returns true once the server has the open (or refused it for good).
    func send(_ body: OpenBody, startedAt: Date) async -> Bool {
        var delay = Backoff.first
        while now().timeIntervalSince(startedAt) < Backoff.deadline {
            var wait: TimeInterval? = nil
            do {
                let (_, resp) = try await session.data(for: try request(body))
                let http = resp as? HTTPURLResponse
                switch outcome(status: http?.statusCode ?? 0, retryAfter: http?.value(forHTTPHeaderField: "retry-after")) {
                case .done: return true
                case .retry(let after): wait = after
                }
            } catch { /* network: back off */ }
            await sleep(wait ?? delay)
            delay = Backoff.next(delay)
        }
        return true // deadline passed: stop trying for this install
    }
}
