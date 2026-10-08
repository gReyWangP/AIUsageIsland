# Authentication Isolation Implementation Plan

> 使用 executing-plans，在当前会话实施，最后独立只读审阅。

**Goal:** 三平台登录会话按授权尝试/账号隔离。
**Architecture:** 可注入的 IsolatedOAuthBrowser + 现有 LoopbackCallbackServer；智谱必填 UUID 数据空间。
**Tech Stack:** Swift 6, macOS 14, AuthenticationServices, WebKit。
**Spec:** docs/superpowers/specs/2026-10-04-auth-isolation-design.md

## Global Constraints
不改授权端点、redirect URI、PKCE、state 校验、账号文件/身份绑定。用户已授权实施。无 Git，当前基线 /tmp/aiusage-auth-isolation-baseline-20261004。

## Review Focus
临时属性设置先于 start；浏览器失败不降级；取消/超时清理本次会话；旧回调不能关闭新会话；智谱旧账号不回退默认共享空间。

## Task 1 — 隔离浏览器边界
- [x] 新建 AuthenticationIsolationTests.swift：fake session 验证临时配置与取消；浏览器支持策略；禁止不支持隔离时启动。先运行观察缺失接口失败。
- [x] 实现 IsolatedOAuthBrowser.swift：protocol、支持策略、每次 session 清理、原生 ASWebAuthenticationSession 包装。

## Task 2 — 三平台接入
- [x] 两个 OAuth 流以 browser factory 注入，并管理本次实例生命周期；授权 HTTP 服务添加最小注入接口供离线集成测试。
- [x] 智谱 storeIdentifier 改为非可选 UUID，账号构造和清理路径一致。保留独立专用空间，无默认 Cookie 迁移。
- [x] 两平台 fake HTTP 服务 + 本机 callback 测试成功/取消；智谱配置身份与 cookie 空间隔离测试。

## Task 3 — 验证
- [x] 全量 swift test、独立审阅、修复重要发现。
- [x] release 打包与签名资源校验；更新 README 和本轮报告，标注真实登录人工验收限制。

## Ledger
Preflight: Task 1 OAuthBrowserPresenting.start(url:onCancel:) / cancel()，Task 2 两个流消费；每个调用创建新 browser 以确保旧 defer 不关闭新会话。

基线：371 tests / 1 skipped / 0 failures。Task 1/2 complete：59 项相关测试通过；新增 11 项隔离测试。缺失接口 RED 后实现；关闭窗口时换取 token 的问题两个平台均观察到 RED，已修复。
Ruling: legacy UUID 为哨兵，不被 WebKit 接受，映射到固定有效 v4 UUID；账号身份保持不变。
Ruling: 专用 Cookie 空间移除时清理全部站点数据（包含第三方登录站点），下一次加载等待该账号清理完成。

Final review: 无严重/重要发现；真实系统浏览器与网站兼容性仍需人工验收。最终完整测试 382 tests / 1 skipped / 0 failures。

Task 3: complete — release 构建、资源、临时签名校验通过，README/结构说明/本轮报告已同步；未安装或发布。
