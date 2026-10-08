# Account Reminder Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement inline, task by task.

**Goal:** Add account-purpose summaries and move menu-bar account selection into the account page; persist and deliver reminders independently per account without changing quota cards.

**Architecture:** Persist AccountAlertPolicy by AccountReference.id. Evaluate every saved account using its isolated runtime, with account-specific queues, notification identifiers and scheduling records. Keep common schedule, snooze and system permission shared. Migrate existing platform reminder settings only to the corresponding currently selected account; new accounts start disabled.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Combine, UserNotifications.

**Spec:** User-approved comparison proposals 1 and 3, excluding proposal 2; labels are user-defined names, never inferred account roles.

## Global Constraints

- Preserve existing quota/detail cards and official-announcement presentation.
- Keep one menu-bar item and at most four displayed accounts.
- Preserve account IDs, grants and custom names; no real account login during verification.
- Preserve direct remove and ordering controls.
- Common reminder schedule and snooze apply to all accounts; explicit appointments remain independent of these rules.

## Review Focus

- Renaming or switching accounts must not transfer settings or cancel another account's appointment.
- Simultaneous alerts for the same metric must not replace each other.
- Hidden accounts with enabled alerts must be monitored, removed accounts must be stopped.
- Disable/remove during awaited notification delivery must discard only the affected account's notification.
- Legacy preferences migrate once, while newly added accounts remain disabled.

## Tasks

- [x] Add policy persistence/migration and tests for rename, defaults and hidden monitoring in AccountReminderSettings.swift, IslandSettings.swift and IslandModel+Accounts.swift.
- [x] Add account-scoped alert tests; update UsageAlerts.swift evaluation, queues, system identifiers and account-targeted actions.
- [x] Make QuotaReminder.swift appointments account-scoped, update validation and click routing, test independent save/cancel and old-format loading.
- [x] Add AccountMenuBarSettingsView and AccountAlertSettingsView; move account selection and add status/purpose summaries while preserving direct remove and sorting.
- [x] Run focused tests, then swift test; inspect native settings renders; package dist/AIUsageIsland.app and update README.


## Verification and Review

- Added 12 account-reminder regression tests, including same-window dual delivery, custom thresholds, hidden monitoring, rename persistence, independent appointment cancellation, removal cleanup, stale-data enable, hidden detail routing, in-flight account switching and V1 decoding.
- Confirmed the switching and V1 compatibility defects with failing tests before fixes. Existing opposite-event-switch regression also passes.
- Full `swift test`: 303 tests, 1 explicit live-network probe skipped, 0 failures (2026-10-03).
- Captured and inspected native 480×680 account/settings screens and reminder pages in both themes. Existing compact/detail layout render tests pass unchanged.
- Independent read-only review found two defects; both fixed and re-reviewed with no new substantive findings.
- `./scripts/build-app.sh` completed release build, resources and strict ad-hoc signature verification; output `dist/AIUsageIsland.app`.
- No live account login, second app instance or real notification delivery performed. Real macOS delivery remains an installation check.
