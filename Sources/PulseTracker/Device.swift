import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(StoreKit)
import StoreKit
#endif
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif

/// Everything that touches the device. The Foundation-only core stays testable on macOS.
enum Device {
    /// App Tracking Transparency status — READ only, never prompts (your app
    /// decides whether to ask). PulseTracker sends an iPhone conversion back
    /// to Meta/TikTok only when this is `authorized`.
    static func attStatus() -> String? {
        #if canImport(AppTrackingTransparency) && os(iOS)
        switch ATTrackingManager.trackingAuthorizationStatus {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return nil
        }
        #else
        return nil
        #endif
    }

    @MainActor static func signals() -> Signals {
        var s = Signals(
            os_version: ProcessInfo.processInfo.operatingSystemVersionString.split(separator: " ").dropFirst().first.map(String.init),
            languages: Array(Locale.preferredLanguages.prefix(8)),
            timezone: TimeZone.current.identifier,
            screen_pts: nil,
            scale: nil
        )
        #if canImport(UIKit) && !os(watchOS)
        s.os_version = UIDevice.current.systemVersion
        let b = UIScreen.main.bounds.size
        s.screen_pts = [Double(b.width), Double(b.height)]
        s.scale = Double(UIScreen.main.scale)
        #endif
        return s
    }

    /// Reads the clipboard only when it holds a URL, and returns it only when it
    /// is PulseTracker's own matching link. `detectedPatterns` never shows the
    /// iOS paste prompt, so people who did not come from a link never see it.
    static func handoffFromClipboard() async -> String? {
        #if canImport(UIKit) && os(iOS)
        // Off the main thread on purpose: reading `string` shows iOS's paste
        // prompt and BLOCKS the calling thread until the person answers. On
        // the main thread that freezes the app right at launch (and the iOS
        // watchdog may kill a launch that hangs too long).
        return await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let pb = UIPasteboard.general
                guard pb.hasStrings else { return done.resume(returning: nil) }
                pb.detectPatterns(for: [\.probableWebURL]) { result in
                    guard case .success(let found) = result, found.contains(\.probableWebURL) else {
                        return done.resume(returning: nil)
                    }
                    DispatchQueue.global(qos: .userInitiated).async {
                        done.resume(returning: pb.string.flatMap { Handoff.token(in: $0) })
                    }
                }
            }
        }
        #else
        return nil
        #endif
    }

    /// App Store build = production; TestFlight / Xcode = sandbox; Simulator = test.
    static func environment() async -> PulseEnvironment {
        #if targetEnvironment(simulator)
        return .test
        #else
        #if canImport(StoreKit)
        if #available(iOS 16.0, macOS 13.0, *) {
            if let result = try? await AppTransaction.shared {
                switch result {
                case .verified(let t), .unverified(let t, _):
                    return t.environment == .production ? .production : .sandbox
                }
            }
        }
        #endif
        if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" { return .sandbox }
        return .production
        #endif
    }
}
