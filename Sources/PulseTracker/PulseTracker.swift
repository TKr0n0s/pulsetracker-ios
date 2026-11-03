import Foundation

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
    }

    /// Call after your user logs in (RevenueCat `logIn`) so the new id is known.
    public static func identify(_ appUserID: String) {
        Task.detached(priority: .utility) { await Runner.shared.run(appUserID: appUserID) }
    }
}

/// Serializes every report: one open at a time, state never raced.
actor Runner {
    static let shared = Runner()
    private var sender: Sender?
    private var environment: PulseEnvironment = .production
    private let store = Store()

    func configure(_ s: Sender, env: PulseEnvironment) { sender = s; environment = env }

    func run(appUserID: String?) async {
        guard let sender else { return }
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
        } else if let id = appUserID, id != store.sentUserId {
            // Later identity (login): same open, new id — the server backfills it.
            body = OpenBody(open_id: store.openId, environment: environment.rawValue,
                            app_user_id: id, clipboard_token: nil, install_referrer: nil, signals: Signals())
        } else {
            return
        }

        store.pending = body
        let started = store.firstAttemptAt ?? Date()
        if store.firstAttemptAt == nil { store.firstAttemptAt = started }
        if await sender.send(body, startedAt: started) {
            store.pending = nil
            store.firstAttemptAt = nil
            if let id = body.app_user_id { store.sentUserId = id }
        }
    }
}
