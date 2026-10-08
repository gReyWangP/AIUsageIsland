# Application Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Deliver signed, in-app downloads and installation from GitHub with automatic checking initially disabled.

**Architecture:** Sparkle owns update transport, trust, installation and preference persistence. An independent MainActor service exposes update availability and preferences to the settings view; app lifecycle retains the service. Packaging embeds the pinned framework; a publishing script generates a signed appcast from the exact release archive.

**Tech Stack:** Swift 6, macOS 14+, SwiftUI, Sparkle 2.9.6, SwiftPM, Python 3, GitHub Releases.

**Spec:** `docs/superpowers/specs/2026-10-08-app-updates-design.md`

## Global Constraints

- 自动检查默认关闭，后来用户选择跨启动保留；不在启动时覆盖。
- 不默认静默下载或安装。手动检查在自动检查关闭时继续可用。
- 源码保持私有，安装包和更新信息通过现有公开分发仓库发布。
- 私钥仅保存在本机钥匙串，不上传、不进入文件或日志。
- 发布标题和说明以功能、变化及安装方式为主，不包含测试数量或“测试版”文案。
- 初次接入版本需要手动安装一次；1.19.14 本身没有更新组件。
- 无 Developer ID 时不宣称 Apple 公证；使用隔离副本验收真实替换。

## Review Focus

1. 已开启自动检查的用户再次启动：保留开启状态，关闭后手动检查仍可用（Task 1）。
2. 悬浮设置窗口遮挡更新对话框：手动/后台展示均正常置前（Task 2）。
3. 框架缺失或签名失败：构建报错并保留旧产物（Task 3）。
4. 清单签名、长度或版本与资产不一致：生成/验收失败，不发布坏清单（Task 4）。
5. 临时签名包下载后替换失败或影响真实账号：隔离验收并记录真实结果（Task 5）。

### Task 1: Update service and production configuration

**Files:** create `Sources/DeepSeekIsland/AppUpdateService.swift`, `Tests/DeepSeekIslandTests/AppUpdateTests.swift`, `Tests/BuildScripts/check_update_configuration.py`; modify `Package.swift`, `Info.plist`; track `Package.resolved`.

**Interfaces:** `@MainActor protocol AppUpdateBackend`: `canCheckForUpdates: Bool { get }`, `automaticallyChecksForUpdates: Bool { get set }`, `onChange: (() -> Void)? { get set }`, `checkForUpdates()`; `AppUpdateService(backend:beforePresentation:)` publishes read-only availability and automatic preference, exposes `setAutomaticChecks(_:)` and `checkForUpdates()`.

- [x] Write plist regression assertions and service tests for preservation, manual check while disabled, rejected duplicate checks and restored availability.
  ```python
  import plistlib
  from pathlib import Path
  info = plistlib.loads(Path('Info.plist').read_bytes())
  assert info.get('SUEnableAutomaticChecks') is False
  assert info.get('SUAutomaticallyUpdate') is False
  assert info['SUFeedURL'] == 'https://raw.githubusercontent.com/gReyWangP/AIUsageIsland-releases/main/appcast.xml'
  ```
- [x] Run `python3 Tests/BuildScripts/check_update_configuration.py`; expect missing update configuration failure before implementation.
- [x] Pin `.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")`; add `.product(name: "Sparkle", package: "Sparkle")` to executable dependencies and `-rpath @executable_path/../Frameworks` linker setting. Implement backend using `SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: ...)`, observe updater properties with Combine. Start only for a configured production `.app` bundle. Generate Ed25519 key via official `generate_keys`, store returned public key in `SUPublicEDKey`. Set both plist automatic flags false without runtime writes.
- [x] Run `swift test --filter AppUpdateTests` and configuration check; expect all pass. Commit service/configuration.

### Task 2: Settings and lifecycle

**Files:** create `Sources/DeepSeekIsland/AppUpdateSettingsView.swift`; modify `Sources/DeepSeekIsland/main.swift`, `IslandSettingsView.swift`, `UtilitySettingsView.swift`, `SupportSettingsView.swift`; test `Tests/DeepSeekIslandTests/AppUpdateTests.swift` and existing settings render tests.

**Interfaces:** consumes Task 1 service; `AppUpdateSettingsView(service: AppUpdateService)` observes service. Optional `updater: AppUpdateService? = nil` passed from AppDelegate through existing settings constructors, preserving callers in tests.

- [x] Add render regression for 软件更新, 检查更新 and 自动检查更新 using injected backend; run filtered tests and expect absent view failure.
- [x] Render current version plus `Button("检查更新", action: service.checkForUpdates).disabled(!service.canCheckForUpdates)` and toggle binding to the service setter. Retain production service in AppDelegate. Close floating settings window before Sparkle UI and activate the app; use standard user driver delegate for scheduled UI. Replace outdated support text with in-app update instructions and public download links.
- [x] Run `swift test --filter 'AppUpdate|UtilitySettingsRender'`; expect pass. Commit UI/lifecycle.

### Task 3: Embed, sign and validate

**Files:** modify `scripts/build-app.sh`, `scripts/validate-app.sh`, `Tests/BuildScripts/check_build_safety.py`.

**Interfaces:** consumes resolved binary framework at `.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework`; outputs valid `.app` with `Contents/Frameworks/Sparkle.framework`.

- [x] Extend fixture with a resource bundle and missing framework, asserting failed build preserves sentinel and reports framework absence. Run safety check, expect failure against old script.
- [x] Require framework before staging; `ditto` into Contents/Frameworks to preserve links. Sign nested XPC/helper apps and framework from inside out; in formal mode use Developer ID plus runtime/timestamp, local mode ad-hoc. Validate with `codesign --verify --deep --strict`, framework/helper presence, plist flags/public key/feed, and executable `otool -L` / `otool -l` runpath.
- [x] Run `python3 Tests/BuildScripts/check_build_safety.py`, `scripts/build-app.sh releases/1.19.15`, `scripts/validate-app.sh releases/1.19.15/AIUsageIsland.app local`; expect pass. Commit packaging.

### Task 4: Reusable signed appcast generation

**Files:** create `scripts/generate-update-feed.py`, `Tests/BuildScripts/check_update_feed.py`, `docs/updates-publishing.md`; public repository `releases/github-distribution/appcast.xml`, README and release notes.

**Interfaces:** script takes `--archive ZIP --appcast XML --sign-tool PATH --notes FILE`; extracts exact packaged plist, requires stable version/integer build/public key, runs official `sign_update` using keychain and validates its length/signature output. Generates XML enclosure with GitHub tag/filename URL, version, minimum OS, signature and byte count; retains older items while replacing same build. No private key argument or stored private material.

- [x] Write archive fixture tests for exact ZIP byte count, version, XML escaping, invalid/missing metadata and no output on sign failure. Run tests; expect script missing failure.
- [x] Implement using `zipfile`, `plistlib`, `subprocess`, `xml.etree.ElementTree`; write XML atomically only after signing succeeds. Document official tools version, keychain backup responsibility, stable signing key, asset-before-feed publication order and initial manual installation.
- [x] Run `python3 Tests/BuildScripts/check_update_feed.py`; expect pass. Generate feed from final archive and verify signature with official verification option. Commit publishing tooling.

### Task 5: Acceptance and publication

**Files:** `Info.plist` version 1.19.15/build 64; release archive, SHA256SUMS and verification logs under ignored `releases/1.19.15`; private/public repo documentation.

**Interfaces:** consumes Tasks 1–4 app and generator; outputs private commit, public GitHub release v1.19.15 and HTTPS appcast.

- [x] Run complete `swift test`, build safety/configuration/feed checks and release build; expect zero failures. Request whole-change independent review and fix material findings.
- [x] Use official `sparkle-cli` with a disposable host bundle, unique bundle ID and isolated local feed signed by the configured key. Install a newer disposable archive; verify on-disk version changed. Corrupt archive/signature and require rejection. Do not launch the real account-bearing app or overwrite installed app.
- [ ] Create final ZIP with `ditto -c -k --keepParent`, compute SHA256SUMS, generate appcast and function-oriented release notes. Upload into draft GitHub release using authorized gh/curl; confirm asset name, size and digest before publication. Publish release then push public appcast. Push private implementation commit; verify remote identities and raw HTTPS feed matches assets.
- [ ] Report release link, automatic default OFF, in-app download/install after first manual installation, and any actual unresolved limitation. Public release text contains functionality only.

## Self-review

Spec coverage: lifecycle/UI → Tasks 1–2; default-off/persistence → Task 1; trust/feed → Task 4; nested packaging → Task 3; isolated replacement/publication → Task 5. Shared interfaces are the service, signed app bundle and exact ZIP; all consumers use their producer's names. No additional account or hover behavior changes.
