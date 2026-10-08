# Usage Domain Implementation Plan

> 当前会话按 executing-plans 执行，测试驱动，完成后独立只读审阅。

**Goal:** 业务指标和窗口计算不再依赖菜单栏实现。
**Architecture:** UsageMetric/UsageReading 属于 Foundation 业务层，QuotaWindowState 统一读取，UI 用兼容别名及显示扩展。
**Tech Stack:** Swift 6 / macOS 14 / SwiftPM；无第三方依赖。
**Spec:** docs/superpowers/specs/2026-10-04-usage-domain-design.md

## Global Constraints

不改变配置键、枚举 rawValue、Codable 编码结构、通知 ID、账号目录、接口或既有 UI；保留当前 Pro 无限窗口行为及日/月窗口。

## Review Focus

有限与无限优先级；无额度窗口与余额；无效日期/百分比；旧 JSON 字典与预约读写；错误缓存不得误发提醒。

## Task 1 — 行为与编码保护

- [x] 新增 UsageDomainTests，以现有接口验证负比例不能显示健康余量、无效日期不能预约或补查、余额没有 quota window。
- [x] swift test --filter UsageDomainTests，观察预期失败；保留当前基线测试结果。
- [x] 加入旧提醒策略/预约 JSON 字面量兼容测试及 Pro 有限/无限消费者一致性测试。

## Task 2 — 业务提取与统一计算

- [x] 新建 UsageMetric.swift 与 UsageReading.swift；旧菜单栏名称作为 typealias，UI 颜色/金额排版保留在显示层。
- [x] 新建 QuotaWindowState.swift；有限窗口验证百分比与时间；AccountRuntime 在此统一平台窗口选择。
- [x] 通知/阈值/预约/补查改为业务类型；窗口 reset date 共用同一读取；菜单栏仅代理业务读数。
- [x] swift test --filter 'UsageDomainTests|ChatGPT|Reset|Quota|MenuBar|Account' 验证相关行为。

## Task 3 — 完整验证与记录

- [x] 完整 swift test；独立只读代码审阅，修复重要发现。
- [x] release 打包与签名/资源验证；更新结构和本轮报告。

## 记录

当前目录仍无 Git；新基线存于 /tmp/aiusage-domain-baseline-20261004，不使用上轮旧副本回写。保留分阶段架构，不将全部网络错误重构混入本轮。

## 执行记录

重新读取并保留当前 Pro 无限制实现；原基线 350 tests / 1 skipped / 0 failures。
Task 1: complete — 原实现对非法比例、非法日期、余额窗口语义有 10 个失败断言；JSON 兼容用例通过。
Task 2: complete — UsageMetric/UsageReading 已提取到 Foundation 文件；窗口选择、重置日期与补查统一。相关 212 tests / 1 skipped / 0 failures。
补充：详情快照同样应用 FiniteQuotaWindow 校验；新快照用例 RED（4 个失败断言）后实现。
Ruling: 除菜单栏展示文件的兼容 typealias 外，业务及其调用方使用新类型名；枚举 rawValue 与 JSON 结构不变。不是持久化迁移。
Ruling: 非有限重置时间仅去除调度，保留有效百分比；负数/非有限百分比则整个窗口未知，避免制造满额度。

Task 3: complete — 最终全量 357 tests / 1 skipped / 0 failures；release 打包、资源与 ad-hoc 签名校验通过。
独立只读审阅未发现严重或重要回归；发现超过 100% 使用量显示被截断，补充失败回归用例后修正为保留实际已用比例、剩余最低 0%，最终全量验证已覆盖。
既有 ChatGPTAuthFlow.start() 返回值警告仍存在；真实登录和系统通知投递未进行人工验证。
