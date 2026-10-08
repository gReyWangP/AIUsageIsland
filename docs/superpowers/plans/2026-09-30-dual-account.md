# Dual Account Island Implementation Plan

**Goal:** Allow simultaneous DeepSeek and Zhipu CodingPlan logins with independent data and a two-column Mac island when both are active.

**Architecture:** Persist enabled platforms as a set, migrate the single selected platform setting, and keep each platform's connection, loading, error, and refresh lifecycle separate. DeepSeek keeps its existing grant and ledger. Zhipu keeps its WebKit session and quota. A derived presentation mode controls single/dual compact geometry and detail width.

**Data:** DeepSeek compact metrics are today's Token and cost. Zhipu compact metrics are 5-hour and weekly used percentage because CodingPlan does not expose a pay-as-you-go daily charge in the existing quota response. No fabricated daily cost.

**Files:**
- `IslandModel.swift`: dual platform state, per-platform login/logout/refresh, saved selection migration.
- `IslandView.swift`: add-account controls, independent account sections, dual compact and detail layouts.
- `NotchLayout.swift`, `main.swift`: dynamic compact height and detail hit area.
- `Tests/DeepSeekIslandTests`: state and geometry regression tests.
- `README.md`, `Info.plist`: document behavior and release 1.8.0.

**Checks:**
- [x] Existing DeepSeek grant remains available after upgrade.
- [x] Logging out of either account retains the other account's data and session.
- [x] Both refresh independently; stale callback after logout cannot reconnect.
- [x] One account uses compact single-row and detail single column.
- [x] Both accounts use compact double-height and detail two columns.
- [x] Tests, release build, signed app ZIP, source ZIP, Downloads copies verified.
