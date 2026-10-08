# Account login window layering fix — 2026-10-03

User reported that the CodingPlan login window launched from account settings was obscured by the settings page and top detail panel. Startup optimization is explicitly out of scope.

## Root cause

The island panel uses `statusBar` (25), settings use `statusBar + 1` (26), but the CodingPlan login window used the default normal level (0). Making the login window key could not override this level ordering. Successful CodingPlan login also unconditionally called `showDetails`, closing a visible settings page.

## Changes

- The production CodingPlan window factory now uses `statusBar + 2` (27), joins all Spaces and supports full-screen auxiliary presentation. `showLogin` additionally orders the window front regardless of app activation.
- Successful login keeps a visible settings page open and brings it forward; otherwise it opens details as before.
- DeepSeek/ChatGPT browser authorization temporarily lowers the app's settings and island windows to the normal level, preserving their visibility and original levels. Completion restores the levels and returns focus to the appropriate app surface. Automatic hover does not steal foreground during this authorization.
- Settings created after browser authorization starts are registered immediately. Repeated login-state events do not overwrite the original levels.
- Account authorization, grant storage and Token refresh behavior are unchanged.

## Validation

Five new tests exercise real AppKit window levels and `NSApplication.orderedWindows`, including raising settings and island after login, restoring levels, retaining hidden-window visibility, and settings created during authorization. The latter was confirmed failing (26 versus 0) before its fix.

The full suite passed: 308 tests, 1 explicit live-network test skipped, 0 failures. Independent read-only review identified the new-window edge case; it was fixed and re-reviewed with no new substantive findings.

No real platform login or second production instance was launched. Actual live browser authorization still needs a user check after reopening the updated app. `./scripts/build-app.sh` completed successfully, including release compilation, resources and strict ad-hoc signature verification. Updated output: `dist/AIUsageIsland.app`. Packaging log: `/tmp/ai-usage-login-window-package.log`.
