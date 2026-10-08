# Startup latency investigation — 2026-10-03

Reported symptom: approximately 1–2 seconds from Finder double-click to visible application response. User confirmed the first launch after upgrading is the most noticeable; this agrees with the observed first-run versus subsequent-run difference.

## Evidence

- The live app was left running; no second production instance was launched and no real grants were read or refreshed by the diagnostic helper.
- The packaged app is a release build, 6.4 MB executable, ad-hoc signed. Bundle contains provenance metadata, no quarantine attribute was listed.
- Existing process start reported by `ps`: 20:07:23 local. System `syspolicyd` logged Gatekeeper evaluation for `com.deepseekisland.app` at 20:07:25.744. This demonstrates evaluation during this launch; it does not by itself measure how long evaluation blocked the app.
- A separate helper linked against the debug module, using temporary defaults, no grants, offline account model and a fake notification backend, measured entry into its own top-level code from process spawn.

| Measurement | First run after rebuild | Second run | Third run |
| --- | ---: | ---: | ---: |
| Spawn to main entry | 2555.4 ms | 7.9 ms | 8.0 ms |
| Synchronous setup after main entry | 195.8 ms | 202.4 ms | 179.8 ms |
| Process exit | 2754.4 ms | 213.0 ms | 190.3 ms |

Individual setup costs: NSApplication 35–45 ms, settings 0.4–0.9 ms, account model 1.1–1.5 ms, four-account snapshots/migration 2.0–2.1 ms, island window/hosting/layout 82–97 ms, login-item status query 13–14 ms, reminder subscriptions under 1 ms, guide first layout 36–47 ms. The probe intentionally did not create a real menu-bar item, perform network polling, query production notification permissions, or restore a real WebKit session. These numbers are diagnostic evidence rather than a full benchmark of Finder launching the production bundle.

## Code inspection

There is no fixed 1–2 second startup delay. Quota refreshes use async tasks and the launch delegate does not await network responses. In `main.swift`, the island hosting view, menu bar, daily utilities and polling setup precede showing the guide. `LoginLaunchController` synchronously queries `SMAppService.mainApp.status`; this is an unnecessary startup dependency but measured only about 14 ms in the helper. SwiftUI first layout is the largest measured in-process stage. CodingPlan session restoration can initialize WKWebView on the main actor after polling starts; it is not included in this probe.

## Assessment and next steps

The strongest current evidence points to a pre-main delay for a newly built executable, with system security evaluation observed for both the helper and actual bundle. The exact proportion attributable to Gatekeeper versus loader/framework work is not established. It is incorrect to attribute the full 1–2 seconds to account/Token requests.

Before changing behavior, distinguish launch after each rebuild from repeated launches of an unchanged bundle. Add lightweight production launch-stage timestamps in a future optimization to compare process/main entry, first visible surface, service setup and WebKit restoration. A reasonable code optimization is to show the initial surface before nonessential services, and move the login-item status query to the settings page where it is displayed. Do not disable system security checks. Real launch timing still needs measurement on a deliberate restart of the application.

Logs: `/tmp/ai-usage-startup-boundaries.log`, `/tmp/ai-usage-app-startup-security.log`, `/tmp/ai-usage-startup-security.log`. Helper source: `/tmp/ai-usage-startup-probe.swift`. Application source and built bundle were not modified during this investigation.
