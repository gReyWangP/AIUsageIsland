import Combine
import Foundation

extension IslandModel {
    var savedAccounts: [AccountReference] {
        platformAccounts.ordered.flatMap { platform in
            accountProfiles.entries(for: platform).map { AccountReference(platform: platform, profileID: $0.id) }
        }
    }
    func activeAccountReference(for platform: UsagePlatform) -> AccountReference {
        AccountReference(platform: platform, profileID: accountProfiles.active(for: platform).id)
    }
    var visibleAccounts: [AccountReference] {
        let available = Set(savedAccounts)
        if let displaySelection { return displaySelection.validated(against: available).accounts }
        let order = presentationSettings?.orderedPlatforms ?? platformAccounts.ordered
        return Array(order.filter { platformAccounts.enabled.contains($0) }.map(activeAccountReference).prefix(AccountDisplaySelection.limit))
    }
    /// One entry per displayed platform, in the user's display order.
    var visiblePlatforms: [UsagePlatform] {
        var seen = Set<UsagePlatform>()
        return visibleAccounts.map(\.platform).filter { seen.insert($0).inserted }
    }
    var monitoredAccounts: [AccountReference] {
        var accounts = visibleAccounts
        if let settings = presentationSettings, settings.showsMenuBarItem,
           let account = settings.menuBarAccount, savedAccounts.contains(account), !accounts.contains(account) {
            accounts.append(account)
        }
        if let settings = presentationSettings, settings.alertsEnabled {
            for account in savedAccounts where settings.reminderPolicy(for: account, model: self).hasAlerts && !accounts.contains(account) {
                accounts.append(account)
            }
        }
        return accounts
    }
    var orderedSavedAccounts: [AccountReference] {
        visibleAccounts + savedAccounts.filter { !visibleAccounts.contains($0) }
    }
    func accountLabel(_ account: AccountReference) -> String {
        accountProfiles.entries(for: account.platform).first { $0.id == account.profileID }?.label ?? account.platform.title
    }
    func preserveDisplaySelection() {
        let normalized = displaySelection?.validated(against: Set(savedAccounts))
            ?? AccountDisplaySelection(accounts: visibleAccounts)
        if displaySelection != normalized { displaySelection = normalized; persistDisplaySelection() }
    }
    func persistDisplaySelection() {
        guard let displaySelection, let data = try? JSONEncoder().encode(displaySelection) else { return }
        defaults.set(data, forKey: "displayedAccountsV1")
    }
    func setAccountVisible(_ account: AccountReference, visible: Bool) {
        guard !visible || savedAccounts.contains(account) else { return }
        preserveDisplaySelection()
        var selection = displaySelection ?? AccountDisplaySelection()
        guard selection.setVisible(account, visible) else {
            accountManagementError = "最多显示 4 个账号，请先取消一个。"; return
        }
        displaySelection = selection; persistDisplaySelection()
        accountManagementError = nil
        reconcileAccountRuntimes()
        onAccountsChanged?()
    }
    func moveAccount(_ account: AccountReference, by offset: Int) {
        preserveDisplaySelection()
        displaySelection?.move(account, by: offset)
        persistDisplaySelection()
    }
    func removeDisplayedPlatform(_ platform: UsagePlatform) {
        displaySelection = AccountDisplaySelection(accounts: visibleAccounts.filter { $0.platform != platform })
        pendingAutoDisplay = pendingAutoDisplay.filter { $0.platform != platform }
        persistDisplaySelection()
    }
    func accountAuthorizationSucceeded(_ account: AccountReference) {
        guard pendingAutoDisplay.remove(account) != nil else { return }
        if visibleAccounts.count < AccountDisplaySelection.limit {
            setAccountVisible(account, visible: true)
        } else {
            accountManagementError = "账号已保存；已显示 4 个账号，新账号暂不显示。"
        }
    }
    func canChangeAccount(_ platform: UsagePlatform) -> Bool {
        // Browser login is explicit and serialized. Unrelated background refreshes need not block management.
        let loading = platform == .deepSeek ? isLoading : platform == .chatGPT ? chatGPTLoading : zhipuLoading
        guard !isSigningIn, !chatGPTSigningIn, !zhipuSigningIn, !loading,
              !accountRuntimes.contains(where: { $0.key.platform == platform && $0.value.isRefreshing }) else {
            accountManagementError = "这个平台正在登录或刷新，请完成后重试。"; return false
        }
        return true
    }
    func accountRuntime(for account: AccountReference) -> AccountRuntime {
        if let existing = accountRuntimes[account] { return existing }
        let runtime = AccountRuntime(account: account, owner: self)
        accountRuntimes[account] = runtime
        runtimeObservations[account] = runtime.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        return runtime
    }
    func reconcileAccountRuntimes() {
        let valid = Set(savedAccounts), monitored = Set(monitoredAccounts)
        for account in Array(accountRuntimes.keys) {
            guard let runtime = accountRuntimes[account] else { continue }
            if !valid.contains(account) {
                runtime.disposeAccountRuntime()
                accountRuntimes.removeValue(forKey: account); runtimeObservations.removeValue(forKey: account)
            } else if !hasStartedPolling || !monitored.contains(account) { runtime.pauseAccountPolling() }
        }
        if hasStartedPolling {
            for account in monitored { accountRuntime(for: account).startPolling() }
        }
    }
    func stopAccountRuntimes(for platform: UsagePlatform) {
        for account in Array(accountRuntimes.keys) where account.platform == platform {
            accountRuntimes.removeValue(forKey: account)?.disposeAccountRuntime()
            runtimeObservations.removeValue(forKey: account)
        }
    }
    func accountReference(id: String) -> AccountReference? { savedAccounts.first { $0.id == id } }
    func refreshAccount(id: String) async {
        guard let account = accountReference(id: id) else { return }
        await accountRuntime(for: account).refresh(account.platform)
    }
    func signInAccount(id: String) async {
        guard let account = accountReference(id: id), canChangeAccount(account.platform) else { return }
        await selectAccount(account.profileID, platform: account.platform)
        guard accountProfiles.active(for: account.platform).id == account.profileID else { return }
        await signIn(account.platform)
    }
    func removeAccount(_ account: AccountReference) async {
        guard savedAccounts.contains(account), canChangeAccount(account.platform) else { return }
        if accountProfiles.entries(for: account.platform).count == 1 { disconnect(account.platform); await HistoryPersistence.flushAll(); return }
        preserveDisplaySelection(); accountManagementError = nil
        guard clearCredentials(for: account) else { accountManagementError = "无法移除授权，请稍后重试。"; return }
        accountRuntimes.removeValue(forKey: account)?.disposeAccountRuntime()
        runtimeObservations.removeValue(forKey: account)
        accountProfiles.remove(account.profileID, platform: account.platform); persistProfiles()
        pendingAutoDisplay.remove(account)
        onAccountRemoved?(account)
        setAccountVisible(account, visible: false)
        reconcileAccountRuntimes(); onAccountsChanged?()
        await HistoryPersistence.flushAll()
    }
    func reserveQuotaReset(accountID: String, row: DetailMetricRow) async {
        guard let account = accountReference(id: accountID), let metric = row.reservationMetric,
              metric.platform == account.platform, row.resetFresh else { return }
        if let onReserveAccountQuotaReset { onReserveAccountQuotaReset(account, metric) }
        else { reserveQuotaReset(platform: account.platform, row: row) }
    }
    func duplicateChatGPTAccount(_ grant: ChatGPTGrant, excluding id: UUID) -> AccountProfileEntry? {
        accountProfiles.entries(for: .chatGPT).first { entry in
            guard entry.id != id else { return false }
            let saved = accountProfiles.store(for: .chatGPT, entry: entry, root: sessionRoot).readChatGPTGrant()
            if let saved, grant.accessToken == saved.accessToken || grant.refreshToken == saved.refreshToken { return true }
            if let identity = grant.resolvedAccountID, let other = entry.identity ?? saved?.resolvedAccountID { return identity == other }
            return false
        }
    }
}
