# PulseTracker iOS SDK

Tells PulseTracker which link brought each install, so RevenueCat trials,
purchases and renewals are credited to the right link and social network.

## Install (one line of code)

1. Xcode → File → Add Package Dependencies → the PulseTracker iOS package URL
   (public repo pending; for now add this folder as a local package).
2. After RevenueCat is configured:

```swift
import PulseTracker

Purchases.configure(withAPIKey: "appl_…")
PulseTracker.configure(appKey: "pk_…", appUserID: Purchases.shared.appUserID)
```

3. If your app logs users in, after `Purchases.shared.logIn(id)` also call
   `PulseTracker.identify(id)`.
4. In RevenueCat → Integrations → Webhooks, paste the URL and Authorization
   value from PulseTracker → App links → Developer.

That's all. Requires iOS 15+.

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

`PrivacyInfo.xcprivacy` declares User ID, Device ID and Other usage data for
analytics, and UserDefaults access (CA92.1). `NSPrivacyTracking` is `false` —
**owner decision pending**: if it becomes `true` and `api.pulsetracker.io` is
listed as a tracking domain, iOS 17+ blocks the SDK's network calls for every
user who did not allow tracking.

## Develop

```
swift test                                   # core on macOS
xcodebuild -scheme PulseTracker -destination 'generic/platform=iOS' build
```

The request body is pinned by `../contract/open-request.json`, asserted by
both `Tests/PulseTrackerTests` and the worker's `open-api.test.ts`.
