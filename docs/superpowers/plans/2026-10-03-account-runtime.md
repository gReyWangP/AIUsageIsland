# Account Runtime Implementation Plan

> 执行方式：当前会话执行（executing-plans），测试先行，最后独立代码审阅。

**Goal:** 修复账号删除事件并消除账号切换时的运行状态搬运。
**Architecture:** IslandModel 管理账号目录与 UI 编排；AccountRuntime 以不可变 AccountReference 持有单账号状态及请求；已有视图通过兼容代理读取当前账号。
**Tech Stack:** Swift 6 / SwiftUI / AppKit / Combine / SwiftPM。
**Spec:** docs/superpowers/specs/2026-10-03-account-runtime-design.md

## Global Constraints

macOS 14；Swift 6；无第三方依赖；不改变偏好键、账号 ID、授权路径、通知标识和既有排版。

## Review Focus

最后一个非默认账号删除；轮换中隐藏；切换时缓存与身份归属；无用途账号暂停；隐藏提醒账号网络恢复。测试用临时目录、独立 UserDefaults 与模拟网络/通知，不接触真实凭据。

## Task 1 — 删除生命周期

- [x] 在 AccountReminderTests 中经 model.removeAccount 删除最后一个非 legacy 账号，断言真实 UUID 的策略、预约与凭据均清除。
- [x] swift test --filter AccountReminderTests，确认旧代码失败。
- [x] disconnect 在清理前保存账号集合，清理后以该集合发送事件。
- [x] 运行相关账号与提醒测试。

## Task 2 — 固定账号运行实例

- [x] 添加 AccountRuntimeLifecycleTests：选择前后引用一致、状态保留、请求数不变；更新旧测试中“切换会刷新”的预期。
- [x] 先运行新测试确认失败。
- [x] 新建 AccountRuntime.swift 及其快照扩展（授权逻辑保留在运行实例内）；移入单账号数据、认证、刷新和调度。不可变 account、弱 owner，数据目录由 account 决定。
- [x] IslandModel 改为目录与编排，accountRuntime(for:) -> AccountRuntime；移除 copyAccountState/cacheActiveAccount。IslandModel+Compatibility.swift 保留原读取接口以逐步迁移 UI。
- [x] 将数据新鲜度、重置补查和菜单栏本地取值移到 AccountRuntime，根模型仅转发。
- [x] 运行账号、授权、提醒、菜单栏测试并修复回归。

## Task 3 — 监测与恢复一致性

- [x] 加入无用途账号不自动刷新、隐藏提醒账号恢复刷新测试，先验证失败。
- [x] 统一 startPolling/reconcile/recoverDataIfNeeded 使用 monitoredAccounts。账号切换只改选择，移除只清理目标实例。
- [x] 全量 swift test；swift build -c release；核对资源与兼容文档。

## 记录

Ruling: 当前目录不是 Git 仓库，不能建立 worktree 或提交；在 /tmp/aiusage-account-refactor-baseline 保存本轮源码与测试基线，直接修改已授权工作区。
Ruling: 用户已经授权实施评估建议，不重复索取流程批准；按已确认方向执行本轮明确范围。

## 执行进度（2026-10-04）

Task 1: complete — 完整删除测试 RED（配置与预约残留）→ GREEN；账号/授权/提醒 37 tests passed。
Task 2: 主体已提取，新增固定实例/无额外请求测试 RED → GREEN。原全量 338 tests 中菜单栏回调与旧测试数据假设已修复，相关 127 tests passed。
Task 3: 隐藏账号恢复及无用途账号启动测试 RED → GREEN；继续补充设置变化与失败清理验证。
Ruling: PersonalQuotaReminderTests 原来直接改目录并复用旧账号数据；新设计要求账号数据隔离，测试现在为新账号显式提供其自身额度，并增加新账号初始为空断言。未放宽提醒去重断言。

补充验证：删除失败保留运行实例与缓存、提醒设置无需菜单栏即可启动/停止监测、已移除实例不得因 legacy ID 重用重新请求，均已 RED→GREEN。
全量验证：swift test → 341 tests, 1 skipped, 0 failures（2026-10-04）。等待独立审阅与 release 打包结果。
Ruling: 保留平台式兼容代理和现有平台客户端，避免本轮同时改变 UI/接口解析；完整平台适配器和结构化错误仍属后续阶段。若过渡层长期保留，会增加后续接口维护成本。

Task 3: complete — 341 tests / 1 skipped / 0 failures；release 应用组装、资源与签名校验通过。最终独立审阅进行中。

Final review: 独立审阅未发现重大回归；三个继承边界已逐项判断。
Final: fixed 启动后立即隐藏仍发资料请求 — testHidingBeforeQueuedStartupProfileFetchPreventsRequest RED（1 次）→ 增加轮询世代及暂停检查。
Final: fixed 慢轮询结束后隐藏账号仍补查 — testHidingDuringSlowPollPreventsSubsequentResetRequest RED（2 次）→ 后续补查前重新检查暂停/取消。
Ruling: 两个隐藏边界虽为继承问题，按本轮“停止新请求”的要求提升为应修复项；资料读取复用既有注入依赖，测试不请求真实平台。
Final: minor (deferred): 整个平台批量 disconnect 非事务性；若后一个账号文件删除失败，前一个授权可能已经移除。普通单账号删除不走多账号批量循环，本轮保持该兼容接口，后续应按逐账号结果建模；失败时可能需重新登录先前已清除的账号。
Final: Ruling: 完整平台适配器、结构化错误、跨进程锁、去除所有兼容代理及真实网页登录仍是后续范围；本轮自动测试不能证明跨进程或真实服务行为。

Final verification: 两项审阅修复 GREEN；完整 swift test → 343 tests, 1 skipped, 0 failures。
最终 release 重建完成：bash scripts/build-app.sh /tmp/aiusage-account-runtime-20261004 → exit 0；资源 bundle、图标、codesign --verify --strict 均通过。未发布新版本。独立审阅及修复记录见上，本轮范围完成。
