# PulseTracker iOS SDK

Tells PulseTracker which link brought each install, so RevenueCat trials,
purchases and renewals are credited to the right link and social network.

## Install (one line of code)

1. Xcode → File → Add Package Dependencies → paste
   `https://github.com/TKr0n0s/pulsetracker-ios` → Up to Next Major `0.3.0`.
2. After RevenueCat is configured:

```swift
import PulseTracker

Purchases.configure(withAPIKey: "appl_…")
PulseTracker.configure(appKey: "pk_…", appUserID: Purchases.shared.appUserID)
```

3. If your app logs users in, after `Purchases.shared.logIn(id)` also call
   `PulseTracker.identify(id)`. If your quiz or landing page collected the
   person's email or phone, pass it too — `PulseTracker.identify(id, email: email)`
   — to see which web funnel each customer came through (hashed by PulseTracker,
   never stored as typed).
4. In RevenueCat → Integrations → Webhooks, paste the URL and Authorization
   value from PulseTracker → App links → Developer.

That's all. Requires iOS 15+.

## Paywall views (optional)

Adds a "Saw a paywall" step to your funnel:

```swift
PulseTracker.paywallShown(placement: "onboarding")   // when your paywall appears
PulseTracker.paywallClosed(placement: "onboarding")  // dismissed without buying
```

- **Superwall:** in `handleSuperwallEvent`, on `.paywallOpen` call
  `PulseTracker.paywallShown(placement: …, source: .superwall)`.
- **RevenueCat Paywalls (no code):** RevenueCat → Integrations → PostHog →
  Self-hosted, domain `https://api.pulsetracker.io/ph`, API key = your PulseTracker
  app key, enable "Send Paywall events". (Experimental: verify your first events.)

## What it does

- On the first launch only, it checks whether the clipboard holds a link
  (without reading it, so iOS shows no prompt). Only if it does, it reads it and
  keeps it only when it is exactly PulseTracker's matching link
  (`https://<link domain>/h/<token>` with nothing after it, or `pt1_<token>`).
  Only the token is uploaded — never the copied text itself.
  iOS may show "Allow Paste" to people who copied a link.
- Sends one install report: a random install id, your RevenueCat user id, the
  matching link (if any), OS version, languages, time zone, screen size.
- Retries with backoff (1 s → 1 h) for up to 24 h, across app restarts.
- Detects the environment: App Store = `production`, TestFlight/Xcode =
  `sandbox`, Simulator = `test`. Override with `environment:`.

## Testing it yourself (before customers)

Sandbox installs only match **test clicks**, and only join RevenueCat
**sandbox** purchases — exactly what TestFlight produces.

1. Create a link in PulseTracker; open it on the iPhone with `?pt_test=1`
   added to the end, e.g. `https://go.pulsetracker.io/abc?pt_test=1`.
2. On the page, tap the button (iPhone code match or Auto inside Instagram) so
   the matching link is copied.
3. Install the TestFlight build, open it, allow paste if asked.
4. App links → Overview should show the open as exact within a minute.
5. Buy a sandbox subscription; it should appear under that link.

## Privacy

`PrivacyInfo.xcprivacy` declares User ID, Device ID, Other usage data, and
Email address / Phone number (only sent when you pass them to `identify`) for
analytics, plus UserDefaults access (CA92.1). `NSPrivacyTracking` is `false`:
the data is used only for your own attribution. Listing `api.pulsetracker.io`
as a tracking domain would make iOS 17+ block the SDK for users who did not
allow tracking.

## Develop

```
swift test                                   # core on macOS
xcodebuild -scheme PulseTracker -destination 'generic/platform=iOS' build
```

Source of truth is `sdks/ios` in the PulseTracker monorepo; this public repo is
a mirror. The request body is pinned by `sdks/contract/open-request.json`
(asserted by the Swift tests and the worker's `open-api.test.ts`).
