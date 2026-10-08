# Usage Analysis Implementation Plan
> **For agentic workers:** use superpowers:executing-plans. User explicitly approved implementation; proceed inline.
**Goal:** Deliver the approved three-platform usage analysis.
**Spec:** docs/superpowers/specs/2026-10-06-usage-analysis.md
**Architecture:** Typed daily buckets + account-owned persisted store; authenticated adapters supply official snapshots; shared analysis window and overview view consume these stores.
**Constraints:** No repository/Git available; snapshot baseline /tmp/aiusage-analysis-baseline instead of commits/worktrees. No production auth reads or second app launch. Use existing request and account identity boundaries.
## Tasks
- [x] 1. Domain, source parsers, persistence and calculations. Produces UsageAnalysisSnapshot/DailyUsageBucket/UsageAnalysisStore; consumes TokenFormatter. Tests: gaps, weighted cache rate, unknown fields, negative/overflow, account files, replacement rather than adding snapshots, consecutive full-day averages.
- [x] 2. Integrate sources. ChatGPT GET backend-api/wham/profiles/me per saved grant after quota rotation. DeepSeek existing amount/cost query expands to 30 days and retains categories. Zhipu same-account browser requests official legacy/credit usage after verified quota, whitelisted statistics only, independent callback and error. Consumes typed snapshot/store; preserves quota behavior and refresh limiter.
- [x] 3. Shared analysis window (account selection, 7/30 days, bar+average line, selected day, Token/cost/cache tabs), detail hover overview in both layouts and settings entry. Consumes runtime store and custom account labels. No source/metric mixing.
- [x] 4. Regression tests, render check, release build/signature, docs/version. Review Focus: real API shape changes, browser identity races, returned coverage, same-day partial replacement, account removal and stale response handling, unit consistency.
**Verification:** swift test; scripts/build-app.sh; codesign --verify --strict dist/AIUsageIsland.app. Expected: all tests passing except pre-existing explicitly skipped network test, valid signed bundle.

## Completion evidence
- RED→GREEN: domain/store, official source parsing, actual JS identity change and delayed identity recovery, long official history, independent multi-account/no-quota stats, minimum titled window area.
- Final swift test: /tmp/aiusage-analysis-final3-full.log, 412 tests, 1 pre-existing network test skipped, 0 failures (2026-10-06).
- Final build/signature: /tmp/aiusage-analysis-final-build.log; 1.19.0 build 49, release succeeded, ad-hoc deep/strict signature verified.
- Fresh readonly reviewer closed identity contamination, short/empty snapshot loss and initial identity recovery issues.
- Native light/dark screenshots for all three platforms, synthetic fixture data, exported to releases/1.19.0. Three-account stacked detail measured 477 pt < 491 pt half-screen bound.
- Rulings: independent analysis window with settings entry, preserve sparse history with per-day cached labels, source UTC is an explicit interpretation rather than verified official time zone. No Git available, baseline backup retained instead of commits.
- Real authenticated API responses remain unverified; never read Codex auth, re-login, or launch another production app for verification.
