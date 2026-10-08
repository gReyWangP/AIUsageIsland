# ChatGPT Adapter Implementation Plan

> 使用 executing-plans 在当前会话实施，最后一次独立只读审阅。

**Goal:** 完成 ChatGPT 刷新事务的适配器边界与结构化错误。
**Architecture:** ChatGPTUsageAdapter + UsageRefreshFailure；AccountRuntime 持有生命周期与发布状态。
**Tech Stack:** Swift 6 / macOS 14 / SwiftPM。
**Spec:** docs/superpowers/specs/2026-10-04-chatgpt-adapter-design.md

## Global Constraints
保留持久化及账号隔离；不改登录、HTTP 客户端及额度解析器；先保存轮换令牌再请求；取消不报告失败。用户已经授权继续完善，本轮直接执行。无 Git，源码基线在 /tmp/aiusage-adapter-baseline-20261004，无法创建 worktree/commit。

## Review Focus
取消与令牌轮换；删除账号时迟到结果；未知错误文本泄漏；授权重试次数；保存失败不能继续请求。

## Task 1 — 运行时行为保护
- [x] 新建 ChatGPTRefreshAdapterTests.swift，注入 ChatGPTServing：取消保留状态、HTTP 失败保留授权、授权失败清理。
- [x] 运行 swift test --filter ChatGPTRefreshAdapterTests，先观察取消错误被误报的失败。

## Task 2 — 适配器和类型
- [x] 新建 UsageRefreshFailure.swift 与 ChatGPTUsageAdapter.swift。
- [x] 接口：fetch(grant:persistRotatedGrant:isCurrent:) async throws -> ChatGPTQuota；失效检查与取消分别处理，续期返回后先保存。
- [x] AccountRuntime.refreshChatGPT 调用适配器，catch 仅按 UsageRefreshFailure 分类更新兼容字符串与 chatGPTRefreshFailure。
- [x] 测试分类、保存失败、单次续期顺序、失效回调和取消后保留新令牌；运行相关隔离/生命周期测试。

## Task 3 — 验证和记录
- [x] 全量 swift test，独立审阅，修复重要发现。
- [x] bash scripts/build-app.sh /tmp/aiusage-chatgpt-adapter-20261004，检查资源/签名；更新项目结构与结果记录。

## 执行记录
Pre-flight: Task 1/2 使用原 ChatGPTServing 和运行时入口；Task 2 增加结构化失败属性，不变更原服务协议。Task 3 验证同一源码。

Task 1: complete — 当前基线 359 tests / 1 skipped / 0 failures（含新智谱无限周窗口）。取消用例在原实现中产生两个预期失败断言。
Task 2: complete — 34 项相关测试通过，包含 10 项新用例。类型测试首先编译失败确认缺失接口；运行时取消用例已由 RED 转 GREEN。
Ruling: 本轮先完成 ChatGPT 垂直链路；DeepSeek/智谱适配器后续独立推进，避免强行统一 HTTP 与 WebKit 生命周期。

Final review: 一项重要发现：取消后的迟到错误绕过取消检查。新增用例 RED（14 处失败断言），修复为服务错误尊重任务取消；已轮换令牌的本地保存失败仍报告。12 项适配器测试通过，等待最终全量与 release。

最终全量 swift test: 371 tests / 1 skipped / 0 failures；源码相对本轮基线只修改 AccountRuntime.swift，新增两个业务文件与一个测试文件。

Task 3: complete — 独立审阅的重要发现已复现修复；最终全量通过；release 打包、图标/资源与 ad-hoc 签名校验通过。结果记录 docs/2026-10-04-chatgpt-adapter.md。
