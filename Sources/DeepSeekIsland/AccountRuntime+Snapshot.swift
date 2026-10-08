import Foundation

extension AccountRuntime {
    func snapshot(for platform: UsagePlatform) -> PlatformSnapshot {
        var snapshot: PlatformSnapshot = switch platform {
        case .deepSeek: deepSeekSnapshot
        case .zhipu: zhipuSnapshot
        case .chatGPT: chatGPTSnapshot
        }
        snapshot.analysisOverview = UsageAnalysisOverview.make(analysis,platform:platform)
        return snapshot
    }

    // MARK: - DeepSeek

    private var deepSeekSnapshot: PlatformSnapshot {
        let usage = officialUsage
        let usageState = deepSeekUsageFreshness()
        let estimated = usage == nil
        let dayCost = usage?.today.cost ?? totals.today
        let weekCost = usage?.sevenDays.cost ?? totals.lastSevenDays
        let monthCost = usage?.month.cost ?? totals.month

        func row(_ id: String, _ label: String, _ cost: Decimal, _ tokens: Int64?) -> DetailMetricRow {
            DetailMetricRow(
                id: id,
                label: label,
                value: balance == nil ? "—"
                    : UsageFormat.cost(cost, currency: currency, estimated: estimated),
                detail: tokens.map { TokenFormatter.short($0) + " Token" }
            )
        }

        return PlatformSnapshot(
            id: UsagePlatform.deepSeek.rawValue,
            platform: .deepSeek,
            title: UsagePlatform.deepSeek.title,
            compactMetrics: [
                CompactMetric(id: "tokens", label: "今日 Token",
                              value: usage.map { TokenFormatter.short($0.today.tokens) } ?? "—"),
                CompactMetric(id: "cost", label: "今日费用", value: compactTodayCost),
            ],
            heroLabel: "账户余额",
            // 与下面几行的 ¥1.99 保持一致，都带货币符号。
            heroValue: balance.map { UsageFormat.currencySymbol(currency) + UsageFormat.money($0) } ?? "—",
            heroSuffix: currency,
            rows: [
                row("today", "今日", dayCost, usage?.today.tokens),
                row("week", "近 7 天", weekCost, usage?.sevenDays.tokens),
                row("month", "本月", monthCost, usage?.month.tokens),
            ],
            note: usage != nil && (usageState.isCached || usageState.phase == .loading || usageState.lastSuccess == nil)
                ? "用量为缓存，最后成功：\(usageLastUpdated.map { $0.formatted(date: .omitted, time: .shortened) } ?? "未知")"
                : estimated
                ? "用量接口尚未返回可识别数据；费用为本机余额变化估算。"
                : "费用与 Token 取自平台用量接口。",
            accountName: accountDisplayName(accountName, platform: .deepSeek),
            isConnected: accountConnected,
            isSigningIn: isSigningIn,
            error: errorMessage,
            warning: isAvailable ? nil : "余额不足，API 暂不可用",
            refreshText: freshness(for: .deepSeek).label,
            dataFreshness: freshness(for: .deepSeek)
        )
    }

    /// 悬浮条上的费用会带货币符号，估算值前置「≈」。
    private var compactTodayCost: String {
        guard balance != nil else { return "—" }
        return UsageFormat.cost(officialUsage?.today.cost ?? totals.today,
                                currency: currency,
                                estimated: officialUsage == nil)
    }

    // MARK: - 智谱

    private var zhipuSnapshot: PlatformSnapshot {
        let quota = zhipuQuota
        let fiveHour = quotaWindow(for: .zhipuFiveHour).finiteValue
        let weekState = quotaWindow(for: .zhipuWeek)
        let week = weekState.finiteValue
        let noWeeklyLimit = weekState == .unlimited
        return PlatformSnapshot(
            id: UsagePlatform.zhipu.rawValue,
            platform: .zhipu,
            title: UsagePlatform.zhipu.title,
            compactMetrics: [
                CompactMetric(id: "five", label: "5 小时剩余",
                              value: UsageFormat.remainingPercent(fiveHour?.usedPercent), resetAt: fiveHour?.resetAt),
                CompactMetric(id: "week", label: noWeeklyLimit ? "本周额度" : "本周剩余",
                              value: noWeeklyLimit ? "无周限制" : UsageFormat.remainingPercent(week?.usedPercent), resetAt: week?.resetAt),
            ],
            heroLabel: "5 小时已用",
            heroValue: UsageFormat.percent(fiveHour?.usedPercent),
            heroSuffix: nil,
            rows: [
                DetailMetricRow(id: "week", label: noWeeklyLimit ? "本周额度" : "本周已用",
                                value: noWeeklyLimit ? "无周限制" : UsageFormat.percent(week?.usedPercent)),
                DetailMetricRow(id: "five-reset", label: "5 小时重置",
                                value: UsageFormat.resetTime(fiveHour?.resetAt), resetAt: fiveHour?.resetAt, resetUsedPercent: fiveHour?.usedPercent, resetFresh: freshness(for: .zhipu).allowsAlerts, reservationMetric: .zhipuFiveHour),
                DetailMetricRow(id: "week-reset", label: "本周重置",
                                value: noWeeklyLimit ? "无需重置" : UsageFormat.resetTime(week?.resetAt), resetAt: week?.resetAt, resetUsedPercent: week?.usedPercent, resetFresh: !noWeeklyLimit && freshness(for: .zhipu).allowsAlerts, reservationMetric: noWeeklyLimit ? nil : .zhipuWeek),
            ],
            note: quota?.kind == .credits
                ? "按智谱页面的额度点数计算。"
                : "按智谱页面的 Token 限额计算。",
            accountName: accountDisplayName(zhipuAccountName, platform: .zhipu),
            isConnected: zhipuConnected,
            isSigningIn: zhipuSigningIn,
            error: zhipuError ?? zhipuUsageError,
            warning: jointQuotaWarning(for: .zhipu),
            refreshText: freshness(for: .zhipu).label,
            dataFreshness: freshness(for: .zhipu)
        )
    }

    // MARK: - ChatGPT

    private var chatGPTSnapshot: PlatformSnapshot {
        let quota = chatGPTQuota
        let session = quota?.session
        let weekly = quota?.weekly
        let sessionValue = session.flatMap { FiniteQuotaWindow(usedPercent: $0.usedPercent, resetAt: $0.resetAt) }
        let weeklyValue = weekly.flatMap { FiniteQuotaWindow(usedPercent: $0.usedPercent, resetAt: $0.resetAt) }
        // 窗口名跟着接口给的窗口长度走：Plus 是「5 小时／本周」，
        // Team 账号换成周／月时标签自动跟着变。
        let unlimited = quota?.hasUnlimitedFiveHour == true && session?.windowSeconds == nil
        let sessionLabel = unlimited ? "5 小时" : (session?.label ?? "5 小时")
        let weeklyLabel = weekly?.label ?? "本周"
        return PlatformSnapshot(
            id: UsagePlatform.chatGPT.rawValue,
            platform: .chatGPT,
            title: UsagePlatform.chatGPT.title,
            compactMetrics: [
                CompactMetric(id: "session", label: sessionLabel + "剩余",
                              value: unlimited ? "无限制" : UsageFormat.remainingPercent(sessionValue?.usedPercent), resetAt: unlimited ? nil : sessionValue?.resetAt),
                CompactMetric(id: "week", label: weeklyLabel + "剩余",
                              value: UsageFormat.remainingPercent(weeklyValue?.usedPercent), resetAt: weeklyValue?.resetAt),
            ],
            heroLabel: sessionLabel + (unlimited ? "额度" : "已用"),
            heroValue: unlimited ? "无限制" : UsageFormat.percent(sessionValue?.usedPercent),
            heroSuffix: nil,
            rows: [
                DetailMetricRow(id: "week", label: weeklyLabel + "已用",
                                value: UsageFormat.percent(weeklyValue?.usedPercent)),
                DetailMetricRow(id: "session-reset", label: sessionLabel + "重置",
                                value: unlimited ? "无需重置" : UsageFormat.resetTime(sessionValue?.resetAt), resetAt: unlimited ? nil : sessionValue?.resetAt, resetUsedPercent: unlimited ? nil : sessionValue?.usedPercent, resetFresh: !unlimited && freshness(for: .chatGPT).allowsAlerts, reservationMetric: unlimited ? nil : .quotaMetric(for: .chatGPT, windowSeconds: session?.windowSeconds)),
                DetailMetricRow(id: "week-reset", label: weeklyLabel + "重置",
                                value: UsageFormat.resetTime(weeklyValue?.resetAt), resetAt: weeklyValue?.resetAt, resetUsedPercent: weeklyValue?.usedPercent, resetFresh: freshness(for: .chatGPT).allowsAlerts, reservationMetric: .quotaMetric(for: .chatGPT, windowSeconds: weekly?.windowSeconds)),
            ] + (quota?.hasUnlimitedFiveHour == true && !unlimited ? [
                DetailMetricRow(id: "five-hour-unlimited", label: "5 小时额度", value: "无限制")
            ] : []),
            // 说明必须短到 220 pt 列宽（三平台时的下限）里只占一行，
            // 否则三列共用的行网格会被它撑高，三平台详情比双平台高一截。
            note: "额度窗口与 Codex 同源。",
            accountName: accountDisplayName(chatGPTAccountName, platform: .chatGPT),
            isConnected: chatGPTConnected,
            isSigningIn: chatGPTSigningIn,
            error: chatGPTError ?? chatGPTUsageError,
            warning: jointQuotaWarning(for: .chatGPT),
            refreshText: freshness(for: .chatGPT).label,
            dataFreshness: freshness(for: .chatGPT)
        )
    }

}
