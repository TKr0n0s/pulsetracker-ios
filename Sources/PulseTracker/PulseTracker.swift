import Foundation
#if canImport(UIKit) && os(iOS)
import UIKit
#endif

/// PulseTracker app-links SDK.
///
///     // after Purchases.configure(...)
///     PulseTracker.configure(appKey: "pk_…", appUserID: Purchases.shared.appUserID)
///
/// On the first launch it reports the install once (with the copied matching
/// link, if the visitor tapped one), retrying for up to 24 h across launches.
/// Revenue comes from your RevenueCat webhook; the app user id joins the two.
public enum PulseTracker {
    /// Call once at launch, after RevenueCat is configured.
    /// - Parameters:
    ///   - appKey: the app key from PulseTracker → App links → Settings.
    ///   - appUserID: `Purchases.shared.appUserID`, so purchases join this install.
    ///   - environment: leave nil to detect (App Store = production, TestFlight/Xcode = sandbox, Simulator = test).
    public static func configure(
        appKey: String,
        appUserID: String? = nil,
        environment: PulseEnvironment? = nil,
        apiBase: URL = URL(string: "https://api.pulsetracker.io")!
    ) {
        Task.detached(priority: .utility) {
            let env: PulseEnvironment
            if let environment { env = environment } else { env = await Device.environment() }
            await Runner.shared.configure(Sender(apiBase: apiBase, appKey: appKey), env: env)
            await Runner.shared.run(appUserID: appUserID)
        }
        observeForeground()
    }

    #if canImport(UIKit) && os(iOS)
    nonisolated(unsafe) private static var foregroundObserver: NSObjectProtocol?
    #endif

    /// Your app may ask for tracking at any time; when it comes back to the
    /// foreground the SDK reports a changed status (a no-op otherwise).
    private static func observeForeground() {
        #if canImport(UIKit) && os(iOS)
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task.detached(priority: .utility) { await Runner.shared.run(appUserID: nil) }
        }
        #endif
    }

    /// Call after your user logs in (RevenueCat `logIn`) so the new id is known.
    /// Pass the email/phone your quiz or landing page collected to link this
    /// customer to the web funnel they came through (hashed server-side, never stored raw).
    public static func identify(_ appUserID: String, email: String? = nil, phone: String? = nil) {
        Task.detached(priority: .utility) { await Runner.shared.run(appUserID: appUserID, email: email, phone: phone) }
    }

    /// Call when a paywall becomes visible (adds "Saw a paywall" to your funnel).
    /// Superwall: call it from `handleSuperwallEvent` on `.paywallOpen` with `source: .superwall`.
    public static func paywallShown(placement: String? = nil, source: PaywallSource = .sdk) {
        Task.detached(priority: .utility) { await Runner.shared.event("paywall_view", placement: placement, source: source) }
    }

    /// Call when a paywall is dismissed without a purchase.
    public static func paywallClosed(placement: String? = nil, source: PaywallSource = .sdk) {
        Task.detached(priority: .utility) { await Runner.shared.event("paywall_close", placement: placement, source: source) }
    }
}

/// Serializes every report: one open at a time, state never raced.
actor Runner {
    static let shared = Runner()
    private var sender: Sender?
    private var environment: PulseEnvironment = .production
    private let store = Store()

    private var waiting: [CheckedContinuation<Sender, Never>] = []

    func configure(_ s: Sender, env: PulseEnvironment) {
        sender = s; environment = env
        let w = waiting; waiting = []
        for c in w { c.resume(returning: s) }
    }

    /// Calls made right after `configure` (identify, paywall events) can reach
    /// the actor before configure finished detecting the environment: they
    /// wait for it instead of being dropped.
    private func ready() async -> Sender {
        if let sender { return sender }
        return await withCheckedContinuation { waiting.append($0) }
    }

    /// One paywall event; retried like the open, keyed by its own id so the server stores it once.
    func event(_ name: String, placement: String?, source: PaywallSource) async {
        let sender = await ready()
        let body = EventBody(event_id: UUID().uuidString.lowercased(), open_id: store.openId, name: name,
                             source: source.rawValue, placement: placement.map { String($0.prefix(120)) },
                             environment: environment.rawValue, at: Date().timeIntervalSince1970 * 1000)
        _ = await sender.send(body, path: "v1/app/event", startedAt: Date())
    }

    private var tail: Task<Void, Never>?

    /// One report at a time. The actor is reentrant at every `await` (clipboard
    /// read, network), so without this the configure run and the foreground
    /// run could both take the first-launch branch: two paste prompts, two
    /// reports. Each call waits for the previous one to finish.
    func run(appUserID: String?, email: String? = nil, phone: String? = nil) async {
        let previous = tail
        let next = Task { await previous?.value; await self.runOnce(appUserID: appUserID, email: email, phone: phone) }
        tail = next
        await next.value
    }

    private func runOnce(appUserID: String?, email: String?, phone: String?) async {
        let sender = await ready()
        var body: OpenBody
        if let pending = store.pending {
            body = pending
            if let id = appUserID, body.app_user_id == nil { body.app_user_id = id }
        } else if !store.reported {
            // First launch: the only time the clipboard is looked at.
            body = OpenBody(
                open_id: store.openId,
                environment: environment.rawValue,
                app_user_id: appUserID,
                clipboard_token: await Device.handoffFromClipboard(),
                install_referrer: nil,
                signals: await Device.signals()
            )
            store.reported = true
        } else if let id = appUserID, id != store.sentUserId || email != nil || phone != nil {
            // Later identity (login): same open, new id — the server backfills it.
            body = OpenBody(open_id: store.openId, environment: environment.rawValue,
                            app_user_id: id, clipboard_token: nil, install_referrer: nil, signals: Signals())
        } else if let att = Device.attStatus(), att != store.sentAtt {
            // The app asked for tracking after the first open: report the new status.
            body = OpenBody(open_id: store.openId, environment: environment.rawValue,
                            app_user_id: appUserID ?? store.sentUserId, clipboard_token: nil, install_referrer: nil, signals: Signals())
        } else {
            return
        }
        if email != nil { body.email = email }
        if phone != nil { body.phone = phone }
        body.att = Device.attStatus()

        store.pending = body
        let started = store.firstAttemptAt ?? Date()
        if store.firstAttemptAt == nil { store.firstAttemptAt = started }
        if await sender.send(body, startedAt: started) {
            store.pending = nil
            store.firstAttemptAt = nil
            if let id = body.app_user_id { store.sentUserId = id }
            if let att = body.att { store.sentAtt = att }
        }
    }
}
