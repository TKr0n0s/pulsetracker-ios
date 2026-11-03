import XCTest
@testable import PulseTracker

/// Stubbed network: a queue of (status, headers) answers; records requests.
final class StubProtocol: URLProtocol {
    static var answers: [(Int, [String: String])] = []
    static var seen: [URLRequest] = []
    static var bodies: [Data] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        StubProtocol.seen.append(request)
        if let s = request.httpBodyStream {
            s.open(); var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            s.close(); StubProtocol.bodies.append(d)
        } else if let b = request.httpBody { StubProtocol.bodies.append(b) }
        let (code, headers) = StubProtocol.answers.isEmpty ? (200, [:]) : StubProtocol.answers.removeFirst()
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class CoreTests: XCTestCase {
    var sleeps: [TimeInterval] = []
    func sender() -> Sender {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        var s = Sender(apiBase: URL(string: "https://api.example.test")!, appKey: "pk_test")
        s.session = URLSession(configuration: cfg)
        s.sleep = { [weak self] t in self?.sleeps.append(t) }
        return s
    }
    let body = OpenBody(open_id: "3f2c9a8e-1b4d-4c6e-9a7f-2d1e0b9c8a76", environment: "production",
                        app_user_id: "u1", clipboard_token: nil, install_referrer: nil, signals: Signals())

    override func setUp() { StubProtocol.answers = []; StubProtocol.seen = []; StubProtocol.bodies = []; sleeps = [] }

    /// The JSON the SDK sends is exactly the shared contract the worker tests replay.
    func testEncodesTheSharedContract() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../contract/open-request.json").standardized
        // The contract lives in the PulseTracker monorepo; the public mirror skips it.
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("contract fixture lives in the monorepo") }
        let fixture = try JSONDecoder().decode(OpenBody.self, from: Data(contentsOf: url))
        let roundTrip = try JSONDecoder().decode(OpenBody.self, from: JSONEncoder().encode(fixture))
        XCTAssertEqual(roundTrip, fixture)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture)) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["open_id", "environment", "app_user_id", "clipboard_token", "signals"])
        XCTAssertEqual(Handoff.token(in: fixture.clipboard_token!), fixture.clipboard_token, "the SDK uploads the pt1_ form")
    }

    func testIdentifyCarriesEmailAndPhone() throws {
        var b = body
        b.email = "ana@example.com"; b.phone = "+5511912345678"; b.att = "authorized"
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(b)) as? [String: Any])
        XCTAssertEqual(json["email"] as? String, "ana@example.com")
        XCTAssertEqual(json["phone"] as? String, "+5511912345678")
        XCTAssertEqual(json["att"] as? String, "authorized")
        XCTAssertNil(try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])["email"])
    }

    func testRequestShape() throws {
        let r = try sender().request(body)
        XCTAssertEqual(r.url?.absoluteString, "https://api.example.test/v1/app/open")
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-PT-App-Key"), "pk_test")
        XCTAssertEqual(r.httpMethod, "POST")
    }

    func testOnlyPulseTrackerLinksLeaveTheClipboard() {
        XCTAssertEqual(Handoff.token(in: "https://go.pulsetracker.io/h/AbCdEfGhIjKlMnOp_123"), "pt1_AbCdEfGhIjKlMnOp_123")
        XCTAssertEqual(Handoff.token(in: "https://links.customer.app/h/AbCdEfGhIjKlMnOp_123"), "pt1_AbCdEfGhIjKlMnOp_123")
        XCTAssertEqual(Handoff.token(in: "  pt1_AbCdEfGhIjKl  "), "pt1_AbCdEfGhIjKl")
        // Never upload someone else's URL that merely contains /h/
        XCTAssertNil(Handoff.token(in: "https://docs.example.com/team/h/PrivateDoc_12345"))
        XCTAssertNil(Handoff.token(in: "https://go.pulsetracker.io/h/AbCdEfGhIjKlMnOp?secret=1"))
        XCTAssertNil(Handoff.token(in: "https://go.pulsetracker.io/h/AbCdEfGhIjKlMnOp#frag"))
        XCTAssertNil(Handoff.token(in: "https://user:pw@go.pulsetracker.io/h/AbCdEfGhIjKlMnOp"))
        XCTAssertNil(Handoff.token(in: "https://go.pulsetracker.io/h/AbCdEfGhIjKlMnOp/extra"))
        XCTAssertNil(Handoff.token(in: "https://example.com/some/page"))
        XCTAssertNil(Handoff.token(in: "http://go.pulsetracker.io/h/AbCdEfGhIjKlMnOp"), "https only")
        XCTAssertNil(Handoff.token(in: "https://go.pulsetracker.io/h/short"))
        XCTAssertNil(Handoff.token(in: "my bank password 1234"))
        XCTAssertNil(Handoff.token(in: "pt1_has spaces in it"))
    }

    func testRetryRulesMatchTheServer() {
        XCTAssertEqual(outcome(status: 200, retryAfter: nil), .done)
        XCTAssertEqual(outcome(status: 400, retryAfter: nil), .done)
        XCTAssertEqual(outcome(status: 401, retryAfter: nil), .done)
        XCTAssertEqual(outcome(status: 429, retryAfter: "30"), .retry(after: 30))
        XCTAssertEqual(outcome(status: 429, retryAfter: "99999"), .retry(after: 3600))
        XCTAssertEqual(outcome(status: 503, retryAfter: nil), .retry(after: nil))
        XCTAssertEqual(Backoff.next(2000), 3600)
    }

    func testSendRetriesThenStops() async {
        StubProtocol.answers = [(503, [:]), (429, ["Retry-After": "7"]), (200, [:])]
        let ok = await sender().send(body, startedAt: Date())
        XCTAssertTrue(ok)
        XCTAssertEqual(StubProtocol.seen.count, 3)
        XCTAssertEqual(sleeps, [1, 7])
    }

    func testSendGivesUpAfter24h() async {
        StubProtocol.answers = [(503, [:])]
        let ok = await sender().send(body, startedAt: Date().addingTimeInterval(-25 * 3600))
        XCTAssertTrue(ok)
        XCTAssertEqual(StubProtocol.seen.count, 0)
    }

    func testStoreKeepsOpenIdAndPendingAcrossLaunches() {
        let d = UserDefaults(suiteName: "pt-test-\(UUID())")!
        let a = Store(d), b = Store(d)
        XCTAssertEqual(a.openId, b.openId)
        XCTAssertNotNil(UUID(uuidString: a.openId))
        a.pending = body
        XCTAssertEqual(b.pending, body)
        a.pending = nil
        XCTAssertNil(b.pending)
    }

    func testPaywallEventRequest() throws {
        let e = EventBody(event_id: "b4f5e1c2-3b4d-4e5f-9a8b-7c6d5e4f3a2c", open_id: body.open_id, name: "paywall_view",
                          source: "superwall", placement: "onboarding", environment: "production", at: 1)
        let r = try sender().request(e, path: "v1/app/event")
        XCTAssertEqual(r.url?.absoluteString, "https://api.example.test/v1/app/event")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: r.httpBody!) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "paywall_view")
        XCTAssertEqual(json["source"] as? String, "superwall")
    }
}
