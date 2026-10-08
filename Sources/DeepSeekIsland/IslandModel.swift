import Combine
import Foundation

/// Account catalogue and application coordination. Data belongs to AccountRuntime.
@MainActor
final class IslandModel: ObservableObject {
    private static let selectedPlatformKey = "selectedUsagePlatform"
    private static let enabledPlatformsKey = "enabledUsagePlatforms"
    let defaults: UserDefaults
    let sessionRoot: SessionStore
    let authFlow: any PlatformAuthorizing
    let chatGPTAuthFlow: any ChatGPTAuthorizing
    let chatGPTClient: any ChatGPTServing
    let deepSeekClient: any DeepSeekServing
    let deepSeekProfileFetcher: (@MainActor (String) async throws -> AccountProfile)?
    var accountRuntimes: [AccountReference: AccountRuntime] = [:]
    var runtimeObservations: [AccountReference: AnyCancellable] = [:]
    var pendingAutoDisplay = Set<AccountReference>()
    var hasStartedPolling = false
    @Published var displaySelection: AccountDisplaySelection?
    @Published var accountManagementError: String?
    @Published var accountProfiles: AccountProfiles
    @Published var platformAccounts: PlatformAccounts
    @Published var notificationDetailAccount: AccountReference?
    @Published var detailFocus: DetailFocusTarget?
    let officialResetCard = OfficialResetCardState()
    private var monitoringObservation: AnyCancellable?
    var presentationSettings: IslandSettings? {
        didSet {
            monitoringObservation = presentationSettings?.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.reconcileAccountRuntimes() }
            reconcileAccountRuntimes()
        }
    }
    var onAccountRemoved: ((AccountReference) -> Void)?
    var onReserveAccountQuotaReset: ((AccountReference, UsageMetric) -> Void)?
    var onReserveQuotaReset: ((UsageMetric) -> Void)?
    var onAccountContextChanged: ((UsagePlatform) -> Void)?
    var onZhipuConnected: (() -> Void)?
    var onPlatformSelected: (() -> Void)?
    var onAccountsChanged: (() -> Void)?
    @Published var networkAvailable = true {
        didSet { for runtime in accountRuntimes.values { runtime.networkAvailable = networkAvailable } }
    }
    @Published var isSleeping = false {
        didSet { for runtime in accountRuntimes.values { runtime.isSleeping = isSleeping } }
    }

    init(defaults: UserDefaults = .standard, sessionRoot: SessionStore = .shared,
         deepSeekAuth: any PlatformAuthorizing = PlatformAuthFlow(),
         chatGPTAuth: any ChatGPTAuthorizing = ChatGPTAuthFlow(),
         deepSeekProfileFetcher: (@MainActor (String) async throws -> AccountProfile)? = nil,
         chatGPTClient: any ChatGPTServing = ChatGPTAccountClient(),
         deepSeekClient: any DeepSeekServing = PlatformAccountClient()) {
        self.defaults = defaults; self.sessionRoot = sessionRoot
        authFlow = deepSeekAuth; chatGPTAuthFlow = chatGPTAuth
        self.deepSeekProfileFetcher = deepSeekProfileFetcher; self.chatGPTClient = chatGPTClient
        self.deepSeekClient = deepSeekClient
        let profiles = defaults.data(forKey: "accountProfilesV1").flatMap { try? JSONDecoder().decode(AccountProfiles.self, from: $0) } ?? AccountProfiles()
        accountProfiles = profiles
        displaySelection = defaults.data(forKey: "displayedAccountsV1").flatMap { try? JSONDecoder().decode(AccountDisplaySelection.self, from: $0) }
        platformAccounts = PlatformAccounts.restore(stored: defaults.stringArray(forKey: Self.enabledPlatformsKey),
            legacy: defaults.string(forKey: Self.selectedPlatformKey),
            hasDeepSeekGrant: profiles.store(for: .deepSeek, root: sessionRoot).readPlatformToken() != nil,
            hasChatGPTGrant: profiles.store(for: .chatGPT, root: sessionRoot).readChatGPTGrant() != nil)
    }

    func selectedRuntime(for platform: UsagePlatform) -> AccountRuntime {
        accountRuntime(for: activeAccountReference(for: platform))
    }
    func startPolling() { hasStartedPolling = true; reconcileAccountRuntimes() }
    func pauseAccountPolling() {
        hasStartedPolling = false
        for runtime in accountRuntimes.values { runtime.pauseAccountPolling() }
    }
    func refresh() async {
        for account in monitoredAccounts where savedAccounts.contains(account) {
            await accountRuntime(for: account).refresh(account.platform)
        }
    }
    func refresh(_ platform: UsagePlatform) async { await selectedRuntime(for: platform).refresh(platform) }
    func signIn(_ platform: UsagePlatform) async { await selectedRuntime(for: platform).signIn(platform) }
    func persistProfiles() {
        if let data = try? JSONEncoder().encode(accountProfiles) { defaults.set(data, forKey: "accountProfilesV1") }
    }
    private func persistPlatformAccounts() {
        defaults.set(platformAccounts.storedValues, forKey: Self.enabledPlatformsKey)
        defaults.removeObject(forKey: Self.selectedPlatformKey)
    }
    func enable(_ platform: UsagePlatform) {
        guard !platformAccounts.enabled.contains(platform) else { return }
        platformAccounts = platformAccounts.adding(platform); persistPlatformAccounts()
        if displaySelection != nil { setAccountVisible(activeAccountReference(for: platform), visible: true) }
        reconcileAccountRuntimes(); onAccountsChanged?(); onPlatformSelected?()
        if platform != .deepSeek { Task { [weak self] in await self?.signIn(platform) } }
    }
    func addAccount(platform: UsagePlatform, label: String) async {
        guard canChangeAccount(platform) else { return }
        preserveDisplaySelection(); accountManagementError = nil
        onAccountContextChanged?(platform)
        if platformAccounts.enabled.contains(platform) { accountProfiles.add(platform: platform, label: label) }
        else {
            platformAccounts = platformAccounts.adding(platform); persistPlatformAccounts()
            accountProfiles.rename(accountProfiles.active(for: platform).id, platform: platform, label: label)
        }
        pendingAutoDisplay.insert(activeAccountReference(for: platform))
        persistProfiles(); reconcileAccountRuntimes()
        await signIn(platform)
    }
    func selectAccount(_ id: UUID, platform: UsagePlatform) async {
        guard canChangeAccount(platform), platformAccounts.enabled.contains(platform),
              accountProfiles.entries(for: platform).contains(where: { $0.id == id }),
              accountProfiles.active(for: platform).id != id else { return }
        preserveDisplaySelection(); accountManagementError = nil
        onAccountContextChanged?(platform)
        accountProfiles.select(id, for: platform); persistProfiles()
        reconcileAccountRuntimes(); onAccountsChanged?()
    }
    func renameAccount(_ id: UUID, platform: UsagePlatform, label: String) {
        accountProfiles.rename(id, platform: platform, label: label); persistProfiles()
    }
    func disconnect(_ platform: UsagePlatform) {
        guard platformAccounts.enabled.contains(platform) else { return }
        let accounts = savedAccounts.filter { $0.platform == platform }
        preserveDisplaySelection()
        for account in accounts {
            guard clearCredentials(for: account) else { accountManagementError = "未能清除账号授权，请稍后重试。"; return }
        }
        // No suspension occurs during file deletion, so invalidate before a pending callback can resume.
        // A failed removal above leaves the existing runtime and its cached data intact.
        stopAccountRuntimes(for: platform)
        accountProfiles.reset(platform); persistProfiles()
        platformAccounts = platformAccounts.removing(platform); persistPlatformAccounts()
        accounts.forEach { onAccountRemoved?($0) }
        removeDisplayedPlatform(platform)
        onAccountsChanged?()
    }
    func removeCurrentAccount(platform: UsagePlatform) async {
        await removeAccount(activeAccountReference(for: platform))
    }
    func clearCredentials(for account: AccountReference) -> Bool {
        guard let entry = accountProfiles.entries(for: account.platform).first(where: { $0.id == account.profileID }) else { return false }
        let store = accountProfiles.store(for: account.platform, entry: entry, root: sessionRoot)
        switch account.platform {
        case .chatGPT:
            guard store.deleteChatGPTGrant() else { return false }
            removeHistory(for: account, store: store)
            return true
        case .deepSeek:
            let token = store.readPlatformToken()
            guard store.deletePlatformToken() else { return false }
            if let token { Task { await PlatformAccountClient().logout(token: token) } }
            removeHistory(for: account, store: store)
            defaults.removeObject(forKey: "platformUsageLedger" + (entry.isLegacy ? "" : "-" + entry.id.uuidString))
            return true
        case .zhipu:
            ZhipuWebSession.clearStore(profileID: entry.id)
            removeHistory(for: account, store: store)
            return true
        }
    }
    private func removeHistory(for account: AccountReference, store: SessionStore) {
        accountRuntimes[account]?.invalidateHistoryStorage()
        for prefix in ["analysis-", "trend-"] {
            HistoryPersistence.removeDirectory(store.directory.appendingPathComponent(prefix + account.platform.rawValue)) { [weak self] success in
                if !success { self?.accountManagementError = "授权已移除，但本机历史文件未能清理，请检查存储权限。" }
            }
        }
    }
    func reserveQuotaReset(platform: UsagePlatform, row: DetailMetricRow) {
        if let metric = row.reservationMetric, metric.platform == platform { onReserveQuotaReset?(metric) }
    }
    var bothConnected: Bool { accountConnected && zhipuConnected }
    var hasTwoColumns: Bool { platformAccounts.enabled.count == 2 }

    var displayedPlatform: UsagePlatform? {
        if accountConnected { return .deepSeek }
        if zhipuConnected { return .zhipu }
        if platformAccounts.enabled.contains(.deepSeek) { return .deepSeek }
        return platformAccounts.enabled.contains(.zhipu) ? .zhipu : nil
    }

    /// 当前已启用平台的展示内容；按用户设置排序，仅筛选悬浮指标。
    /// 排版层只认这个数组，不认识具体平台。
    var snapshots: [PlatformSnapshot] {
        return visibleAccounts.map { account in
            let platform = account.platform
            var snapshot = accountRuntime(for: account).snapshot(for: platform)
            snapshot.id = account.id
            snapshot.title = accountProfiles.entries(for: platform).first { $0.id == account.profileID }?.label ?? platform.title
            if let settings = presentationSettings {
                let visible = settings.visibleMetricIDs(for: platform, allIDs: snapshot.compactMetrics.map(\.id))
                snapshot.compactMetrics = snapshot.compactMetrics.filter { visible.contains($0.id) }
            }
            return snapshot
        }
    }

    /// 只有一个平台时详情宽度收窄到 360，这里给出那个平台。
    var soleSnapshot: PlatformSnapshot? {
        snapshots.count == 1 ? snapshots[0] : nil
    }

}
