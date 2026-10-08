import Foundation

/// Compatibility accessors for platform-oriented views. All state lives in a pinned account runtime.
extension IslandModel {
    var usageLastUpdated: Date? {
        get { selectedRuntime(for: .deepSeek).usageLastUpdated }
        set { selectedRuntime(for: .deepSeek).usageLastUpdated = newValue }
    }
    var balance: Decimal? {
        get { selectedRuntime(for: .deepSeek).balance }
        set { selectedRuntime(for: .deepSeek).balance = newValue }
    }
    var currency: String {
        get { selectedRuntime(for: .deepSeek).currency }
        set { selectedRuntime(for: .deepSeek).currency = newValue }
    }
    var isAvailable: Bool {
        get { selectedRuntime(for: .deepSeek).isAvailable }
        set { selectedRuntime(for: .deepSeek).isAvailable = newValue }
    }
    var isLoading: Bool {
        get { selectedRuntime(for: .deepSeek).isLoading }
        set { selectedRuntime(for: .deepSeek).isLoading = newValue }
    }
    var isSigningIn: Bool {
        get { selectedRuntime(for: .deepSeek).isSigningIn }
        set { selectedRuntime(for: .deepSeek).isSigningIn = newValue }
    }
    var errorMessage: String? {
        get { selectedRuntime(for: .deepSeek).errorMessage }
        set { selectedRuntime(for: .deepSeek).errorMessage = newValue }
    }
    var usageError: String? {
        get { selectedRuntime(for: .deepSeek).usageError }
        set { selectedRuntime(for: .deepSeek).usageError = newValue }
    }
    var officialUsage: OfficialUsageSummary? {
        get { selectedRuntime(for: .deepSeek).officialUsage }
        set { selectedRuntime(for: .deepSeek).officialUsage = newValue }
    }
    var zhipuQuota: ZhipuQuota? {
        get { selectedRuntime(for: .zhipu).zhipuQuota }
        set { selectedRuntime(for: .zhipu).zhipuQuota = newValue }
    }
    var zhipuConnected: Bool {
        get { selectedRuntime(for: .zhipu).zhipuConnected }
        set { selectedRuntime(for: .zhipu).zhipuConnected = newValue }
    }
    var zhipuLoading: Bool {
        get { selectedRuntime(for: .zhipu).zhipuLoading }
        set { selectedRuntime(for: .zhipu).zhipuLoading = newValue }
    }
    var zhipuSigningIn: Bool {
        get { selectedRuntime(for: .zhipu).zhipuSigningIn }
        set { selectedRuntime(for: .zhipu).zhipuSigningIn = newValue }
    }
    var zhipuError: String? {
        get { selectedRuntime(for: .zhipu).zhipuError }
        set { selectedRuntime(for: .zhipu).zhipuError = newValue }
    }
    var zhipuUsageError: String? {
        get { selectedRuntime(for: .zhipu).zhipuUsageError }
        set { selectedRuntime(for: .zhipu).zhipuUsageError = newValue }
    }
    var zhipuLastUpdated: Date? {
        get { selectedRuntime(for: .zhipu).zhipuLastUpdated }
        set { selectedRuntime(for: .zhipu).zhipuLastUpdated = newValue }
    }
    var zhipuAccountName: String? {
        get { selectedRuntime(for: .zhipu).zhipuAccountName }
        set { selectedRuntime(for: .zhipu).zhipuAccountName = newValue }
    }
    var chatGPTQuota: ChatGPTQuota? {
        get { selectedRuntime(for: .chatGPT).chatGPTQuota }
        set { selectedRuntime(for: .chatGPT).chatGPTQuota = newValue }
    }
    var chatGPTConnected: Bool {
        get { selectedRuntime(for: .chatGPT).chatGPTConnected }
        set { selectedRuntime(for: .chatGPT).chatGPTConnected = newValue }
    }
    var chatGPTLoading: Bool {
        get { selectedRuntime(for: .chatGPT).chatGPTLoading }
        set { selectedRuntime(for: .chatGPT).chatGPTLoading = newValue }
    }
    var chatGPTSigningIn: Bool {
        get { selectedRuntime(for: .chatGPT).chatGPTSigningIn }
        set { selectedRuntime(for: .chatGPT).chatGPTSigningIn = newValue }
    }
    var chatGPTError: String? {
        get { selectedRuntime(for: .chatGPT).chatGPTError }
        set { selectedRuntime(for: .chatGPT).chatGPTError = newValue }
    }
    var chatGPTUsageError: String? {
        get { selectedRuntime(for: .chatGPT).chatGPTUsageError }
        set { selectedRuntime(for: .chatGPT).chatGPTUsageError = newValue }
    }
    var chatGPTLastUpdated: Date? {
        get { selectedRuntime(for: .chatGPT).chatGPTLastUpdated }
        set { selectedRuntime(for: .chatGPT).chatGPTLastUpdated = newValue }
    }
    var chatGPTAccountName: String? {
        get { selectedRuntime(for: .chatGPT).chatGPTAccountName }
        set { selectedRuntime(for: .chatGPT).chatGPTAccountName = newValue }
    }
    var lastUpdated: Date? {
        get { selectedRuntime(for: .deepSeek).lastUpdated }
        set { selectedRuntime(for: .deepSeek).lastUpdated = newValue }
    }
    var accountConnected: Bool {
        get { selectedRuntime(for: .deepSeek).accountConnected }
        set { selectedRuntime(for: .deepSeek).accountConnected = newValue }
    }
    var accountName: String? {
        get { selectedRuntime(for: .deepSeek).accountName }
        set { selectedRuntime(for: .deepSeek).accountName = newValue }
    }
    var ledger: UsageLedger {
        get { selectedRuntime(for: .deepSeek).ledger }
        set { selectedRuntime(for: .deepSeek).ledger = newValue }
    }
    var totals: UsageTotals { selectedRuntime(for: .deepSeek).totals }
    var isRefreshing: Bool { accountRuntimes.values.contains { $0.isRefreshing } }
    var canSwitchAccount: Bool { !isSigningIn && !chatGPTSigningIn && !zhipuSigningIn && !isRefreshing }
    var chatGPTAuthorizationContext: String { selectedRuntime(for: .chatGPT).chatGPTAuthorizationContext }
    func activeAccountKey(for platform: UsagePlatform) -> String { activeAccountReference(for: platform).notificationKey }
    func activeAccountLabel(for platform: UsagePlatform) -> String { accountLabel(activeAccountReference(for: platform)) }
    func alertAccountKey(_ metric: UsageMetric) -> String { activeAccountReference(for: metric.platform).alertKey(metric) }
    func snapshot(for platform: UsagePlatform) -> PlatformSnapshot { selectedRuntime(for: platform).snapshot(for: platform) }
    func refreshDeepSeek() async { await selectedRuntime(for: .deepSeek).refreshDeepSeek() }
    func refreshChatGPT() async { await selectedRuntime(for: .chatGPT).refreshChatGPT() }
    func refreshZhipu() async { await selectedRuntime(for: .zhipu).refreshZhipu() }
    @discardableResult func acceptZhipuQuota(_ quota: ZhipuQuota) -> Bool { selectedRuntime(for: .zhipu).acceptZhipuQuota(quota) }
    func rememberChatGPTIdentity(_ grant: ChatGPTGrant) { selectedRuntime(for: .chatGPT).rememberChatGPTIdentity(grant) }
    func noteRefreshAttempt(_ platform: UsagePlatform, at now: Date = .now) { selectedRuntime(for: platform).noteRefreshAttempt(platform, at: now) }
    func canAutomaticallyRefresh(_ platform: UsagePlatform, at now: Date = .now) -> Bool { selectedRuntime(for: platform).canAutomaticallyRefresh(platform, at: now) }
    func automaticRefreshPlatforms(restoringZhipuSession: Bool = false) -> [UsagePlatform] {
        platformAccounts.ordered.filter { selectedRuntime(for: $0).automaticRefreshPlatforms(restoringZhipuSession: restoringZhipuSession).contains($0) }
    }
    func refreshNearQuotaReset() async {
        for account in monitoredAccounts where savedAccounts.contains(account) { await accountRuntime(for: account).refreshNearQuotaReset() }
    }
    func quotaResetDate(for metric: UsageMetric) -> Date? { selectedRuntime(for: metric.platform).quotaResetDate(for: metric) }
    func freshness(for platform: UsagePlatform, at now: Date = .now) -> DataFreshness { selectedRuntime(for: platform).freshness(for: platform, at: now) }
    func recoveryPlatforms(at now: Date = .now) -> [UsagePlatform] {
        platformAccounts.ordered.filter { selectedRuntime(for: $0).recoveryPlatforms(at: now).contains($0) }
    }
    func recoverDataIfNeeded() async {
        for account in monitoredAccounts where savedAccounts.contains(account) { await accountRuntime(for: account).recoverDataIfNeeded() }
    }
    func resetQuotaObservations(at now: Date = .now) -> [ResetQuotaObservation] {
        platformAccounts.ordered.flatMap { selectedRuntime(for: $0).resetQuotaObservations(at: now) }
    }
    func jointQuotaStatus(for platform: UsagePlatform) -> JointQuotaStatus { selectedRuntime(for: platform).jointQuotaStatus(for: platform) }
    func quotaRecoveryContext(for metric: UsageMetric) -> String { selectedRuntime(for: metric.platform).quotaRecoveryContext(for: metric) }
    func jointQuotaWarning(for platform: UsagePlatform) -> String? { selectedRuntime(for: platform).jointQuotaWarning(for: platform) }
    func hasLoadedAccountData(for platform: UsagePlatform) -> Bool { selectedRuntime(for: platform).hasLoadedAccountData(for: platform) }
    func hasConnectedAccount(for platform: UsagePlatform) -> Bool { selectedRuntime(for: platform).hasConnectedAccount(for: platform) }
    func localMenuBarData(for metric: UsageMetric) -> UsageReading { selectedRuntime(for: metric.platform).localMenuBarData(for: metric) }
}
