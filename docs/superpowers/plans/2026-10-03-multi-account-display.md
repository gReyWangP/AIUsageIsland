# Multi-account display implementation plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task by task. User approved implementation in this session.

**Goal:** Show up to four independently refreshed accounts, permit repeated platforms and custom names, and preview both layouts in the actual island from a compact settings window.

**Architecture:** Retain the current per-platform model as the active-account context used by existing menu and reminder integrations. Additional displayed accounts get isolated runtime models with their own profile selection, credential store, refresh generation, quota and ledger. A persistent ordered list of account references controls both compact and detail snapshots. Account-specific actions use the snapshot ID.

**Tech Stack:** Swift 6, SwiftUI, AppKit, macOS 14, existing Swift Package tests; no new dependencies.

**Spec:** Approved conversation: settings around 480 × 680 pt, no embedded full-detail preview, explicit real-size compact/detail preview, unlimited saved accounts, at most four visible accounts, names default to platform then 一/二, all platforms always offered by add.

## Global constraints

- Preserve legacy grants and ledger storage and migrate old platform ordering without requiring login again.
- Never read or modify another application's OAuth credentials; never print tokens.
- Hiding preserves authorization; removing one account affects only its own local credentials.
- Keep compact and detail layout settings independent.
- This checkout has no Git repository: edit in place, preserve a task-local backup, and do not fabricate commits or worktrees.

## Review focus

- Duplicate browser identity: prevent a new ChatGPT slot from reusing an existing account identity or rotating its credentials.
- Stale completion after account switch/removal: old requests cannot save or update the new account.
- Four selected accounts at startup: each reference gets its own data; a fifth remains saved and hidden.
- Hidden and removed accounts: no blank card positions, no stale callbacks or orphan polling workers.
- Small screens: bounded settings content and scrollable lists, true-size detail preview placed above settings without blocking controls.

### Task 1: Profiles and display selection

**Files:** AccountProfiles.swift, AccountDisplaySelection.swift, PlatformManagementState.swift; AccountProfilesTests.swift, PlatformManagementTests.swift, MultiAccountDisplayTests.swift.

- [x] Add regression assertions: `XCTAssertEqual(AccountProfiles().active(for: .chatGPT).label, "ChatGPT")`; blank additions become ChatGPT一 and ChatGPT二; adding candidates equal `UsagePlatform.allCases` even when all enabled. Run `swift test --filter 'AccountProfilesTests|PlatformManagementTests|MultiAccountDisplayTests'` and inspect expected failures.
- [x] Introduce Codable `AccountReference(platform: UsagePlatform, profileID: UUID)` and `AccountDisplaySelection(accounts: [AccountReference])` with unique selection capped at four, move/remove operations, and persisted migration from platform order. Snapshot identity remains platform rawValue for legacy accounts and includes UUID for new profiles.
- [x] Add persistence, cap, duplicate-reference, explicit-empty and unknown-reference tests; run targeted tests until passing.

### Task 2: Independent runtime and authorization

**Files:** IslandModel.swift, IslandModel+Accounts.swift, ChatGPTAccountClient.swift, PlatformAccountClient.swift; MultiAccountDisplayTests.swift, AccountAuthorizationRaceTests.swift.

- [x] Regression: two saved ChatGPT grants plus an ordered selection produce two uniquely identified snapshots and retain each token after rename/switch/hide. `XCTAssertEqual(model.snapshots.count, 2)` must fail before runtime support.
- [x] Add independent inactive-account runtime models, forward observation, refresh only selected extras, dispose on switch/removal, and route refresh/sign-in/removal by account ID. Runtime models cannot mutate global profile selection or recursively create children.
- [x] Serialize refresh for each grant; reject duplicate ChatGPT identity before saving. Validate DeepSeek profile/contact where available and never compare display names as identity. Preserve profile-specific ledger keys and pending accounts until login succeeds.
- [x] Exercise cancellation, duplicate identity, failed storage, selection full, per-account quota/ledger and refresh rotation using temporary stores and injected service dependencies. Run account and refresh suites.

### Task 3: Settings and native preview

**Files:** AccountSettingsView.swift, FloatingContentSettings.swift, IslandSettingsView.swift, UtilitySettingsView.swift, main.swift, IslandSettings.swift; SettingsWindowTests.swift, DetailLayoutTests.swift.

- [x] Add window regression `XCTAssertEqual(window.contentLayoutRect.width, 480)` and height 680. Verify failures against old fixed 420 × 756 window.
- [x] Make account/display management a primary settings tab; checkboxes show N/4, order arrows, inline rename/manage, unrestricted platform picker and default names, no automatic fourth/fifth slot form. Bound content with a ScrollView. Keep metric settings but remove competing platform ordering controls.
- [x] Add `onPreview: (IslandPresentation.Mode) -> Void` and explicit preview buttons for both native surfaces. Position settings below the active island when possible; keep settings above island and constrain to available screen height.
- [x] Render settings and both detail modes with four account snapshots on internal/external geometry; inspect generated images and run window/layout tests.

### Task 4: Account-specific view actions and completion

**Files:** IslandView.swift, IslandDetailColumns.swift, IslandDetailStacked.swift, IslandGuide.swift, README.md; MultiAccountDisplayTests.swift and full suite.

- [x] Add account-ID callback routes alongside compatibility platform callbacks; ensure repeated platform card IDs and matched geometry IDs are unique. Use selected account count for panel sizing. Keep whole-platform deletion explicitly labelled and account deletion individually confirmed.
- [x] Update add button to always offer platforms; empty displayed selection offers settings access without discarding saved accounts. Update guide and documentation for names, four-account selection, token separation and browser-account switching.
- [x] Run `swift test` and `swift build -c release`; inspect all failures. Review modified sources separately against review focus, repair any correctness failures with regression tests, record results below.

## Execution record

- Implementation authorized by user. No Git metadata is present; source/test backup retained outside project. Existing settings are 420 × 756 pt; mockup was wider but product code unchanged before this run.

- Profiles and display-selection regressions were observed failing before implementation, then passed. Existing grants remain in the legacy directory; extra accounts use platform/UUID stores and existing profile-specific ledger keys. Stale selection references are normalized before mutation.
- Independent account refresh was tested with an injected rotating-token service: quotas remain separate, refresh rotation is serialized, hiding retains the new grant, and removing one account retains the other account. Duplicate browser identity/token and stale-login completion tests passed with temporary stores; no real credential files were inspected.
- One read-only review found expired legacy DeepSeek identity lookup rejecting valid reauthorization, account-specific stacked scroll IDs, small-screen settings overlap, and stale selection capacity. These were repaired in one fix pass with regressions. Actual scroll-container tests also exposed SwiftUI ForEach identity overriding nested metric IDs in both detail layouts; the collection IDs now include the account and row. Both weekly-row scrolling tests passed.
- Known identities still prevent silent account replacement. If a legacy DeepSeek grant is expired or its identity cannot be recovered, its lookup does not invalidate a freshly verified login. Duplicate matching cannot reliably distinguish masked contact fields or nicknames. System-browser OAuth retains browser session behavior; the user must switch to the desired account on the authorization page. CodingPlan retains per-profile WebKit isolation.
- Native fixtures were rendered with fake account data: settings 480 × 680 pt, four-account horizontal detail 954 pt wide on 1512 pt screen geometry, vertical detail and both compact modes. Settings screenshots used NSHostingView/AppKit controls. A 768 pt screen placement regression verifies the settings window can shrink below 360 pt without covering the detail preview.
- Final full suite: 285 tests, 1 pre-existing conditional skip, 0 failures (2026-10-03). Fixture images and test/build logs are in the task visualization directory. Live browser authorization and system notification delivery were not exercised; no second real app instance was started.
- Release packaging completed successfully via `scripts/build-app.sh`: `dist/DeepSeekIsland.app` version 1.17.0, icon/resource bundle included, ad-hoc signature verified. Final warning cleanup only joined the stacked return expression onto one line; its 3 native layout/scroll tests were rerun successfully before the final package. The untouched OAuth flow retains its pre-existing unused `start()` result warning.

## Follow-up fixes

- Removal usability: bottom minus now lists saved accounts with custom name and platform, settings rows expose removal directly, and both confirmation dialogs show a named destructive action. Native layout and single-account deletion regressions passed; release package rebuilt.
- Status-bar integration: adding a pending account previously switched the platform context immediately, leaving the status item reading an unfinished account even though another card had valid quota. Menu data, freshness, supported windows, refresh and titles now resolve the same account. An unfinished login or missing first quota response falls back to an authorized account with data. A previously loaded selected account retains ownership during errors; unknown data never borrows another account's quota.
- Right-click menu now names the actual account and window, provides an account selector, disables unfinished accounts, and refreshes the actual source. Unknown quota renders a question mark; a real zero remains critical. Account selection also chooses the existing current-account reminder context; automatic temporary menu fallback does not change reminders.
- Regression observed failing before fixes, covering an unfinished second ChatGPT entry versus an original account with 50% remaining, auto-focus/freshness, refresh availability, unfinished selector state, first-quota-pending fallback, and true zero/update failure. Full suite: 286 tests, 1 explicit live-network skip, 0 failures. Final quick-menu label/test adjustment: 3 targeted tests passed. Live user quota was not independently fetched and no auth data was printed.

- Settings follow-up: the status selector now persists an explicit `AccountReference` separately from its quota window, displays custom account names, and stays independent of the reminder/current-account context. Existing platform-only preferences migrate to an authorized account even before the first quota refresh. Named selection no longer follows newly added/current accounts, and unavailable data remains unknown for that identity. Automatic focus is restricted to the selected account's windows. Right-click selection and settings share the same preference. Selected hidden accounts remain monitored. Tests verify persistence, correct independent quota, rename propagation, zero versus unknown, legacy migration, hidden-account monitoring, and reusing the same NSStatusBarButton when switching accounts. Native settings fixture shows “工作 ChatGPT” and “5 小时剩余额度” as separate selectors. Full suite after migration fix: 288 tests, 1 live-network skip, 0 failures.

- Startup freeze follow-up: status update called runtime reconciliation, which unconditionally assigned a child's published AccountProfiles and then mutated its published selection. That forwarded two root model notifications per redraw and queued another status redraw indefinitely. AccountProfiles now conforms to Equatable; reconciliation prepares the selected copy and assigns only when contents differ. Regression reproduced 10 notifications from 5 unchanged redraws, then verified 0 even after 150 ms of run-loop delivery; genuine rename notifications still occur. Full suite: 289 tests, 1 live-network skip, 0 failures; release package/signature verification passed.
- Manual validation of the packaged app: clicked Next (guide page 2/3), Back (1/3), then Skip (two-account main interface visible). No auth flow was started and no user settings were changed. A later settings-window automation request timed out; its action was not counted as successful. A two-second process sample showed the main thread predominantly waiting for events and process CPU about 0.4%, rather than the feedback loop. Guide button behavior is confirmed; settings-window automation follow-up remains unverified.

- Naming follow-up: package/product executable, `.app` output, CFBundleName/DisplayName, app brand and window titles now use AIUsageIsland to match the workspace project. Internal Swift module remains DeepSeekIsland; the SwiftPM resource bundle prefix and packaged-resource loader were updated to AIUsageIsland_DeepSeekIsland.bundle. Legacy bundle identifier, OAuth/open URL scheme and application data directory are retained so credentials and preferences remain available. Packaged resources, layout, settings window and menu account suites: 12 tests, 0 failures.
