import Combine
import Foundation

/// A stable owner for one account's data, authorization and in-flight requests.
/// Selection and presentation never transfer this state to another instance.
@MainActor
final class AccountRuntime: ObservableObject {
    let account: AccountReference
    let instanceID = UUID()
    weak var owner: IslandModel?
    let defaults: UserDefaults
    let sessionRoot: SessionStore
    let store: SessionStore
    private var historyUpdatesStopped = false
    private var storedTrend: UsageTrendStore?
    private var storedAnalysis: UsageAnalysisStore?
    private var historyObservations = Set<AnyCancellable>()
    var trend: UsageTrendStore {
        if let storedTrend { return storedTrend }
        let value = UsageTrendStore(directory: store.directory.appendingPathComponent("trend-" + account.platform.rawValue, isDirectory: true))
        storedTrend = value
        observeHistory(value.objectWillChange)
        if isDisposed { value.invalidate() }
        if historyUpdatesStopped { value.stopAcceptingUpdates() }
        return value
    }
    var analysis: UsageAnalysisStore {
        if let storedAnalysis { return storedAnalysis }
        let value = UsageAnalysisStore(directory: store.directory.appendingPathComponent("analysis-" + account.platform.rawValue, isDirectory: true))
        storedAnalysis = value
        observeHistory(value.objectWillChange)
        if isDisposed { value.invalidate() }
        if historyUpdatesStopped { value.stopAcceptingUpdates() }
        return value
    }
    private func observeHistory(_ publisher: ObservableObjectPublisher) {
        publisher.receive(on: RunLoop.main).sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &historyObservations)
    }
    func invalidateHistoryStorage() { storedTrend?.invalidate(); storedAnalysis?.invalidate() }
    func stopAcceptingHistoryUpdates() { historyUpdatesStopped = true; storedTrend?.stopAcceptingUpdates(); storedAnalysis?.stopAcceptingUpdates() }
    func finishHistoryLoading() async { await storedTrend?.waitUntilLoaded(); await storedAnalysis?.waitUntilLoaded() }
    private var analysisTask: Task<Void, Never>?
    private var analysisAttempt: Date?
    @Published var networkAvailable = true
    @Published var isSleeping = false
    private(set) var hasStartedPolling = false
    private var isDisposed = false
    @Published var usageLastUpdated: Date?
    @Published private(set) var refreshPolicy = RefreshPolicy()
    private var zhipuPermitHeld = false
    private var refreshDeferred = false
    private var refreshAttempts: [UsagePlatform: Date] = [:]
    @Published var balance: Decimal?
    @Published var currency = "CNY"
    @Published var isAvailable = true
    @Published var isLoading = false
    @Published var isSigningIn = false
    @Published var errorMessage: String?
    @Published private(set) var authorizationIssue: AccountAuthorizationIssue?
    @Published var usageError: String?
    @Published private(set) var deepSeekRefreshFailure: UsageRefreshFailure?
    @Published private(set) var deepSeekUsageFailure: UsageRefreshFailure?
    @Published var officialUsage: OfficialUsageSummary?
    @Published var zhipuQuota: ZhipuQuota?
    @Published var zhipuConnected = false
    @Published var zhipuLoading = false
    @Published var zhipuSigningIn = false
    @Published var zhipuError: String?
    @Published var zhipuUsageError: String?
    @Published private(set) var zhipuRefreshFailure: UsageRefreshFailure?
    @Published var zhipuLastUpdated: Date?
    @Published var zhipuAccountName: String?
    @Published var chatGPTQuota: ChatGPTQuota?
    @Published var chatGPTConnected = false
    @Published var chatGPTLoading = false
    @Published var chatGPTSigningIn = false
    @Published var chatGPTError: String?
    @Published var chatGPTUsageError: String?
    @Published private(set) var chatGPTRefreshFailure: UsageRefreshFailure?
    @Published var chatGPTLastUpdated: Date?
    @Published var chatGPTAccountName: String?
    @Published var lastUpdated: Date?
    @Published var accountConnected = false
    @Published var accountName: String? = nil
    @Published var ledger = UsageLedger()

    private let client: any DeepSeekServing
    private let authFlow: any PlatformAuthorizing
    private let deepSeekProfileFetcher: (@MainActor (String) async throws -> AccountProfile)?
    private var zhipuAdapter: ZhipuUsageAdapter?
    let chatGPTClient: any ChatGPTServing
    private let chatGPTAuthFlow: any ChatGPTAuthorizing
    private var pollTask: Task<Void, Never>?
    private var pollGeneration = 0
    private var resetRefreshSchedule = ResetRefreshSchedule()
    private var sessionVersion = 0
    private var deepSeekLoginVersion = 0
    private var refreshingVersion: Int?
    private var profileRequestVersion: Int?
    private var chatGPTRequestVersion = 0
    private var chatGPTLoginVersion = 0


    init(account: AccountReference, owner: IslandModel) {
        self.account = account; self.owner = owner
        defaults = owner.defaults; sessionRoot = owner.sessionRoot
        let entry = AccountProfileEntry(id: account.profileID, label: account.platform.title)
        store = owner.accountProfiles.store(for: account.platform, entry: entry, root: owner.sessionRoot)
        authFlow = owner.authFlow; chatGPTAuthFlow = owner.chatGPTAuthFlow
        client = owner.deepSeekClient
        deepSeekProfileFetcher = owner.deepSeekProfileFetcher; chatGPTClient = owner.chatGPTClient
        networkAvailable = owner.networkAvailable; isSleeping = owner.isSleeping
        accountConnected = account.platform == .deepSeek && store.readPlatformToken() != nil
        chatGPTConnected = account.platform == .chatGPT && store.readChatGPTGrant() != nil
        if account.platform == .deepSeek, let data = defaults.data(forKey: ledgerStorageKey),
           let saved = try? JSONDecoder().decode(UsageLedger.self, from: data) { ledger = saved }
    }

    var platformAccounts: PlatformAccounts {
        PlatformAccounts(enabled: !isDisposed && owner?.savedAccounts.contains(account) == true ? [account.platform] : [])
    }
    var accountProfiles: AccountProfiles {
        get { owner?.accountProfiles ?? AccountProfiles() }
        set { owner?.accountProfiles = newValue }
    }
    var accountManagementError: String? {
        get { owner?.accountManagementError }
        set { owner?.accountManagementError = newValue }
    }
    func activeAccountReference(for platform: UsagePlatform) -> AccountReference { account }
    func activeAccountKey(for platform: UsagePlatform) -> String { account.notificationKey }
    func persistProfiles() { owner?.persistProfiles() }
    func accountAuthorizationSucceeded(_ platform: UsagePlatform) { owner?.accountAuthorizationSucceeded(account) }
    func rememberChatGPTIdentity(_ grant: ChatGPTGrant) {
        guard let identity = grant.resolvedAccountID, let owner, owner.savedAccounts.contains(account),
              let entry = owner.accountProfiles.entries(for: .chatGPT).first(where: { $0.id == account.profileID }),
              entry.identity == nil || entry.identity == identity else { return }
        owner.accountProfiles.identify(account.profileID, platform: .chatGPT, identity: identity)
        owner.persistProfiles()
    }
    func duplicateChatGPTAccount(_ grant: ChatGPTGrant, excluding id: UUID) -> AccountProfileEntry? {
        owner?.duplicateChatGPTAccount(grant, excluding: id)
    }
    var onAccountsChanged: (() -> Void)? { owner?.onAccountsChanged }
    var onZhipuConnected: (() -> Void)? { owner?.onZhipuConnected }
    private func sessionStore(for platform: UsagePlatform) -> SessionStore { store }
    private var ledgerStorageKey: String {
        "platformUsageLedger" + (account.notificationKey == "legacy" ? "" : "-" + account.profileID.uuidString)
    }
    var chatGPTAuthorizationContext: String { account.id + ":" + instanceID.uuidString + ":\(chatGPTLoginVersion):\(chatGPTRequestVersion)" }
    func accountDisplayName(_ name: String?, platform: UsagePlatform) -> String? {
        guard accountProfiles.entries(for: platform).count > 1 else { return name }
        return (owner?.accountLabel(account) ?? platform.title) + (name.map { " · " + $0 } ?? "")
    }
    var totals: UsageTotals { ledger.totals(now: .now, calendar: .current, currency: currency) }
    func automaticRefreshPlatforms(restoringZhipuSession: Bool = false) -> [UsagePlatform] {
        guard networkAvailable, !isSleeping else { return [] }
        return platformAccounts.ordered.filter { platform in
            switch platform {
            case .deepSeek: accountConnected
            case .chatGPT: chatGPTConnected
            case .zhipu: !zhipuSigningIn && (zhipuConnected || restoringZhipuSession)
            }
        }
    }

    var isRefreshing: Bool { isLoading || zhipuLoading || chatGPTLoading }

    func startPolling() {
        guard !isDisposed else { return }
        hasStartedPolling = true
        guard pollTask == nil else { return }
        pollGeneration += 1
        let pollingVersion = pollGeneration
        if platformAccounts.enabled.contains(.deepSeek) {
            Task { [weak self] in
                guard let self, self.hasStartedPolling, self.pollGeneration == pollingVersion else { return }
                await self.refreshProfile()
            }
        }
        pollTask = Task { [weak self] in
            defer { if self?.pollGeneration == pollingVersion { self?.pollTask = nil } }
            // WebKit 会保留智谱登录，但启动时还没有额度快照：只尝试恢复一次。
            var restoringZhipuSession = true
            var nextRegularRefresh = Date.distantPast
            while !Task.isCancelled, self?.hasStartedPolling == true, self?.owner != nil {
                guard let self else { return }
                if self.refreshDeferred || Date.now >= nextRegularRefresh || (self.refreshPolicy.failures > 0 && self.refreshPolicy.canAttempt()) {
                    for platform in self.automaticRefreshPlatforms(restoringZhipuSession: restoringZhipuSession)
                        where self.canAutomaticallyRefresh(platform) {
                        let loading = platform == .deepSeek ? self.isLoading : platform == .zhipu ? self.zhipuLoading : self.chatGPTLoading
                        guard !loading else { continue }
                        // 普通刷新也算该到期窗口的一次检查，防止紧接着重复请求。
                        self.resetRefreshSchedule.reconcile(self.resetQuotaObservations(), at: .now)
                        self.resetRefreshSchedule.recordAttempt(for: platform, at: .now)
                        await self.refresh(platform, automatic: true)
                    }
                    restoringZhipuSession = self.refreshDeferred
                    nextRegularRefresh = Date.now.addingTimeInterval(300)
                }
                guard self.hasStartedPolling, !Task.isCancelled else { return }
                await self.refreshNearQuotaReset()
                // 仅检查本机时间；普通网络轮询仍为 5 分钟，只有到期窗口会补查。
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func refreshNearQuotaReset() async {
        guard networkAvailable, !isSleeping else { return }
        resetRefreshSchedule.reconcile(resetQuotaObservations(), at: .now)
        for platform in resetRefreshSchedule.duePlatforms(at: .now) where canAutomaticallyRefresh(platform) {
            let loading = platform == .chatGPT ? chatGPTLoading : zhipuLoading
            guard !loading else { continue }
            resetRefreshSchedule.recordAttempt(for: platform, at: .now)
            await refresh(platform, automatic: true)
            resetRefreshSchedule.reconcile(resetQuotaObservations(), at: .now)
        }
    }

    func signIn(_ platform: UsagePlatform) async {
        guard platformAccounts.enabled.contains(platform) else { return }
        authorizationIssue = nil
        if platform == .zhipu {
            zhipuSigningIn = true
            zhipuLoading = false
            zhipuError = nil
            ensureZhipuAdapter().showLogin()
            return
        }
        if platform == .chatGPT {
            guard !chatGPTSigningIn, !chatGPTLoading else { return }
            chatGPTLoginVersion += 1
            let loginVersion = chatGPTLoginVersion
            chatGPTSigningIn = true
            chatGPTError = nil
            defer { if chatGPTLoginVersion == loginVersion { chatGPTSigningIn = false } }
            let profileID = activeAccountKey(for: .chatGPT)
            let grantStore = sessionStore(for: .chatGPT)
            if let saved = grantStore.readChatGPTGrant() { rememberChatGPTIdentity(saved) }
            do {
                var grant = try await chatGPTAuthFlow.signIn()
                grant.accountID = grant.resolvedAccountID
                guard chatGPTLoginVersion == loginVersion, platformAccounts.enabled.contains(.chatGPT), activeAccountKey(for: .chatGPT) == profileID else { return }
                if let duplicate = duplicateChatGPTAccount(grant, excluding: account.profileID) {
                    authorizationIssue = .duplicate(label: duplicate.label)
                    chatGPTError = authorizationIssue?.localizedDescription
                    accountManagementError = chatGPTError
                    return
                }
                let activeID = account.profileID
                let unverifiable = accountProfiles.entries(for: .chatGPT).contains { entry in
                    let saved = accountProfiles.store(for: .chatGPT, entry: entry, root: sessionRoot).readChatGPTGrant()
                    let knownID = entry.identity ?? saved?.resolvedAccountID
                    guard saved != nil || knownID != nil else { return false }
                    if entry.id != activeID { return knownID == nil || grant.resolvedAccountID == nil }
                    return knownID != nil && grant.resolvedAccountID == nil && saved?.accessToken != grant.accessToken
                }
                if unverifiable {
                    authorizationIssue = .unverifiedIdentity
                    chatGPTError = authorizationIssue?.localizedDescription
                    accountManagementError = chatGPTError
                    return
                }
                if let originalID = accountProfiles.entries(for: .chatGPT).first(where: { $0.id == account.profileID })?.identity ?? grantStore.readChatGPTGrant()?.resolvedAccountID,
                   let returnedID = grant.resolvedAccountID, originalID != returnedID {
                    authorizationIssue = .differentAccount
                    chatGPTError = authorizationIssue?.localizedDescription
                    accountManagementError = chatGPTError
                    return
                }
                guard grantStore.saveChatGPTGrant(grant) else {
                    chatGPTError = "无法把 ChatGPT 授权保存到本机应用数据"
                    accountManagementError = chatGPTError
                    return
                }
                rememberChatGPTIdentity(grant)
                onAccountsChanged?()
                chatGPTConnected = true
                accountAuthorizationSucceeded(.chatGPT)
                chatGPTSigningIn = false
                await refresh(.chatGPT)
            } catch {
                guard chatGPTLoginVersion == loginVersion else { return }
                chatGPTError = error.localizedDescription
                accountManagementError = chatGPTError
            }
            return
        }
        guard !isSigningIn, !isLoading else { return }
        deepSeekLoginVersion += 1
        let loginVersion = deepSeekLoginVersion
        isSigningIn = true
        defer { if deepSeekLoginVersion == loginVersion { isSigningIn = false } }
        errorMessage = nil
        let version = sessionVersion
        do {
            let token = try await authFlow.signIn()
            guard deepSeekLoginVersion == loginVersion, platformAccounts.enabled.contains(.deepSeek), version == sessionVersion else { return }
            let profileID = account.profileID
            let profile = try await verifyDeepSeekAuthorization(token: token, profileID: profileID)
            guard deepSeekLoginVersion == loginVersion, version == sessionVersion,
                  account.profileID == profileID else { return }
            guard sessionStore(for: .deepSeek).savePlatformToken(token) else {
                errorMessage = "无法保存账号授权到本机应用数据"
                return
            }
            sessionVersion += 1
            accountConnected = true
            accountProfiles.identify(profileID, platform: .deepSeek, identity: profile.identity)
            persistProfiles()
            accountAuthorizationSucceeded(.deepSeek)
            onAccountsChanged?()
            accountName = profile.displayName
            persistLedger()
            Task { [weak self] in await self?.refreshProfile() }
            Task { [weak self] in await self?.refresh(.deepSeek) }
        } catch {
            guard deepSeekLoginVersion == loginVersion else { return }
            authorizationIssue = error as? AccountAuthorizationIssue
            errorMessage = error.localizedDescription
            accountManagementError = error.localizedDescription
        }
    }

    private func verifyDeepSeekAuthorization(token: String, profileID: UUID) async throws -> AccountProfile {
        func fetch(_ token: String) async throws -> AccountProfile {
            if let deepSeekProfileFetcher { return try await deepSeekProfileFetcher(token) }
            return try await client.fetchProfile(token: token)
        }
        var profile = try await fetch(token)
        for entry in accountProfiles.entries(for: .deepSeek) {
            let existingToken = accountProfiles.store(for: .deepSeek, entry: entry, root: sessionRoot).readPlatformToken()
            let isCurrent = entry.id == profileID
            // Unfinished drafts have neither credentials nor an established identity.
            guard existingToken != nil || entry.identity != nil else { continue }
            if !isCurrent, existingToken == token {
                throw AccountAuthorizationIssue.duplicate(label: entry.label)
            }
            let known = AccountProfile(displayName: entry.label, identity: entry.identity)
            var matches = profile.matchesIdentity(of: known)
            let bothStable = profile.identity?.hasPrefix("user:") == true && entry.identity?.hasPrefix("user:") == true
            if !bothStable, let existingToken, let oldProfile = try? await fetch(existingToken) {
                matches = profile.matchesIdentity(of: oldProfile) ?? matches
            }
            if isCurrent, existingToken == token, profile.identity == nil {
                profile.identity = entry.identity
                continue
            }
            if let matches {
                if !isCurrent && matches {
                    throw AccountAuthorizationIssue.duplicate(label: entry.label)
                }
                if isCurrent && !matches {
                    throw AccountAuthorizationIssue.differentAccount
                }
            } else if !isCurrent || entry.identity != nil {
                throw AccountAuthorizationIssue.unverifiedIdentity
            }
        }
        return profile
    }

    func noteRefreshAttempt(_ platform: UsagePlatform, at now: Date = .now) { refreshAttempts[platform] = now }
    func canAutomaticallyRefresh(_ platform: UsagePlatform, at now: Date = .now) -> Bool {
        refreshPolicy.canAttempt(at: now) && (refreshAttempts[platform].map { now.timeIntervalSince($0) >= 30 } ?? true)
    }

    func refresh(_ platform: UsagePlatform, automatic: Bool = false) async {
        guard networkAvailable, !isSleeping, !isDisposed, !isRefreshing,
              refreshPolicy.canAttempt(manual: !automatic) else { return }
        guard await PlatformRequestLimiter.shared.acquire(platform) else { refreshDeferred = true; return }
        guard !Task.isCancelled, !isDisposed, networkAvailable, !isSleeping, !isRefreshing, refreshPolicy.canAttempt(manual: !automatic) else {
            await PlatformRequestLimiter.shared.release(platform); return
        }
        refreshDeferred = false
        if platform == .zhipu { zhipuPermitHeld = true }
        noteRefreshAttempt(platform)
        switch platform {
        case .deepSeek: await refreshDeepSeek()
        case .zhipu: await refreshZhipu()
        case .chatGPT: await refreshChatGPT()
        }
        if platform != .zhipu {
            let failure = platform == .deepSeek ? RefreshPolicy.balanceFailure(primary: deepSeekRefreshFailure, auxiliary: deepSeekUsageFailure) : chatGPTRefreshFailure
            refreshPolicy.record(Task.isCancelled ? .cancelled : failure)
            if case .rateLimited = failure, let deadline = refreshPolicy.nextAttempt { await PlatformRequestLimiter.shared.pause(platform, until: deadline) }
            await PlatformRequestLimiter.shared.release(platform)
        } else if !zhipuLoading { releaseZhipuPermit() }
    }

    private func releaseZhipuPermit() {
        guard zhipuPermitHeld else { return }; zhipuPermitHeld = false
        Task { await PlatformRequestLimiter.shared.release(.zhipu) }
    }

    func refreshDeepSeek() async {
        guard platformAccounts.enabled.contains(.deepSeek) else { return }
        guard let token = sessionStore(for: .deepSeek).readPlatformToken(),
              refreshingVersion != sessionVersion else { return }
        if accountName == nil {
            Task { [weak self] in await self?.refreshProfile() }
        }
        let version = sessionVersion
        refreshingVersion = version
        isLoading = true
        defer {
            if refreshingVersion == version {
                refreshingVersion = nil
                isLoading = false
            }
        }
        do {
            let result = try await DeepSeekUsageAdapter(service: client).fetch(
                token: token,
                isCurrent: { self.isCurrentSession(token: token, version: version) },
                onBalance: { reading in
                    self.balance = reading.amount
                    self.currency = reading.currency
                    self.isAvailable = reading.amount > 0
                    self.lastUpdated = .now
                    self.trend.record(metric: .deepSeekBalance, value: NSDecimalNumber(decimal: reading.amount).doubleValue, unit: reading.currency, resetAt: nil)
                    self.errorMessage = nil
                    self.deepSeekRefreshFailure = nil
                    self.ledger.record(balance: reading.amount, currency: reading.currency, at: .now)
                    self.persistLedger()
                }
            )
            guard isCurrentSession(token: token, version: version) else { return }
            switch result {
            case .updated(let usage):
                if let snapshot = usage.analysis { analysis.accept(snapshot) }
                officialUsage = usage
                usageLastUpdated = .now
                usageError = nil
                deepSeekUsageFailure = nil
            case .unavailable(let failure):
                analysis.fail("DeepSeek 官方用量暂不可用，已有历史仍保留", failure: failure)
                deepSeekUsageFailure = failure
                usageError = failure == .authorization
                    ? "用量接口未接受当前网页登录授权；余额仍可读取"
                    : "平台用量暂不可用：\(failure.message(for: .deepSeek))"
            }
            objectWillChange.send()
        } catch {
            guard isCurrentSession(token: token, version: version) else { return }
            let failure = DeepSeekUsageAdapter.failure(for: error)
            guard failure != .cancelled else { return }
            if failure == .authorization {
                sessionStore(for: .deepSeek).deletePlatformToken()
                clearDeepSeekState()
                deepSeekRefreshFailure = failure
                errorMessage = failure.message(for: .deepSeek)
                onAccountsChanged?()
            } else {
                deepSeekRefreshFailure = failure
                errorMessage = failure.message(for: .deepSeek)
            }
        }
    }

    func refreshZhipu() async {
        guard platformAccounts.enabled.contains(.zhipu), !zhipuLoading else { return }
        guard ensureZhipuAdapter().refresh() else { return }
        zhipuLoading = true
    }

    /// 拉一次 ChatGPT 额度。
    ///
    /// access token 过期时用**自己那份** refresh token 换新的再试一次。
    /// 绝不能拿 Codex CLI 的 refresh token 来刷——那是一次性令牌，会把用户的 CLI 挤下线。
    func refreshChatGPT() async {
        let grantStore = sessionStore(for: .chatGPT)
        guard platformAccounts.enabled.contains(.chatGPT), !chatGPTLoading, !chatGPTSigningIn,
              let grant = grantStore.readChatGPTGrant() else { return }
        rememberChatGPTIdentity(grant)
        chatGPTLoading = true
        chatGPTRequestVersion += 1
        let requestVersion = chatGPTRequestVersion
        defer { if chatGPTRequestVersion == requestVersion { chatGPTLoading = false } }
        do {
            let quota = try await ChatGPTUsageAdapter(service: chatGPTClient).fetch(
                grant: grant,
                persistRotatedGrant: { grantStore.saveChatGPTGrant($0) },
                isCurrent: { self.chatGPTRequestVersion == requestVersion && self.platformAccounts.enabled.contains(.chatGPT) }
            )
            guard chatGPTRequestVersion == requestVersion,
                  platformAccounts.enabled.contains(.chatGPT) else { return }
            apply(quota)
            scheduleChatGPTAnalysis()
        } catch {
            guard chatGPTRequestVersion == requestVersion,
                  platformAccounts.enabled.contains(.chatGPT) else { return }
            let failure = (error as? UsageRefreshFailure) ?? .unknown
            if failure == .noQuota { scheduleChatGPTAnalysis() }
            guard failure != .cancelled else { return }
            if failure == .authorization {
                grantStore.deleteChatGPTGrant()
                clearChatGPTState()
                chatGPTRefreshFailure = failure
                chatGPTError = failure.message(for: .chatGPT)
                onAccountsChanged?()
            } else {
                chatGPTRefreshFailure = failure
                chatGPTUsageError = "ChatGPT 额度暂不可用：\(failure.message(for: .chatGPT))"
            }
        }
    }

    func refreshUsageAnalysis() async {
        if account.platform == .chatGPT { analysisAttempt = nil }
        await refresh(account.platform)
    }

    private func scheduleChatGPTAnalysis() {
        guard analysisTask == nil, analysisAttempt.map({ Date.now.timeIntervalSince($0) >= 300 }) ?? true else { return }
        analysisTask = Task { [weak self] in await self?.refreshChatGPTAnalysis() }
    }
    private func refreshChatGPTAnalysis() async {
        defer { analysisTask = nil; analysis.isLoading = false }
        guard !isDisposed, networkAvailable, !isSleeping, let grant = store.readChatGPTGrant(),
              await PlatformRequestLimiter.shared.acquire(.chatGPT) else { return }
        guard !isDisposed, !Task.isCancelled, platformAccounts.enabled.contains(.chatGPT) else { await PlatformRequestLimiter.shared.release(.chatGPT); return }
        let version = chatGPTRequestVersion
        analysisAttempt = .now; analysis.isLoading = true
        do {
            let snapshot = try await chatGPTClient.fetchAnalysis(grant:grant)
            if !isDisposed, !Task.isCancelled, chatGPTRequestVersion == version, store.readChatGPTGrant()?.resolvedAccountID == grant.resolvedAccountID { analysis.accept(snapshot); objectWillChange.send() }
        } catch {
            if !isDisposed, !Task.isCancelled, chatGPTRequestVersion == version {
                analysis.fail("ChatGPT 官方日统计暂不可用，已有历史仍保留", failure: .dailyStatisticsFailure(for: error)); objectWillChange.send()
            }
            if case .rateLimited(let until) = error as? UsageRefreshFailure { await PlatformRequestLimiter.shared.pause(.chatGPT, until:until ?? .now.addingTimeInterval(60)) }
        }
        await PlatformRequestLimiter.shared.release(.chatGPT)
    }

    private func apply(_ quota: ChatGPTQuota) {
        let wasConnected = chatGPTConnected
        chatGPTQuota = quota
        chatGPTConnected = true
        chatGPTSigningIn = false
        chatGPTAccountName = quota.planName
        chatGPTLastUpdated = .now
        recordQuotaTrend()
        chatGPTError = nil
        chatGPTUsageError = nil
        chatGPTRefreshFailure = nil
        if !wasConnected { onAccountsChanged?() }
    }

    private func clearChatGPTState() {
        if chatGPTSigningIn { chatGPTAuthFlow.cancel() }
        chatGPTLoginVersion += 1
        chatGPTRequestVersion += 1
        chatGPTLoading = false
        chatGPTSigningIn = false
        chatGPTConnected = false
        chatGPTQuota = nil
        chatGPTError = nil
        chatGPTUsageError = nil
        chatGPTRefreshFailure = nil
        chatGPTLastUpdated = nil
        chatGPTAccountName = nil
    }

    private func refreshProfile() async {
        guard networkAvailable, !isSleeping else { return }
        guard platformAccounts.enabled.contains(.deepSeek),
              let token = sessionStore(for: .deepSeek).readPlatformToken(),
              profileRequestVersion != sessionVersion else { return }
        let version = sessionVersion
        profileRequestVersion = version
        defer {
            if profileRequestVersion == version { profileRequestVersion = nil }
        }
        do {
            let profile: AccountProfile
            if let deepSeekProfileFetcher { profile = try await deepSeekProfileFetcher(token) }
            else { profile = try await client.fetchProfile(token: token) }
            guard isCurrentSession(token: token, version: version), !Task.isCancelled else { return }
            accountName = profile.displayName
        } catch {
            guard isCurrentSession(token: token, version: version), !Task.isCancelled else { return }
            let failure = DeepSeekUsageAdapter.failure(for: error)
            if failure == .authorization {
                sessionStore(for: .deepSeek).deletePlatformToken()
                clearDeepSeekState()
                deepSeekRefreshFailure = failure
                errorMessage = failure.message(for: .deepSeek)
                onAccountsChanged?()
            }
        }
    }

    private func isCurrentSession(token: String, version: Int) -> Bool {
        sessionVersion == version && platformAccounts.enabled.contains(.deepSeek) && accountConnected
            && sessionStore(for: .deepSeek).readPlatformToken() == token
    }

    private func ensureZhipuAdapter() -> ZhipuUsageAdapter {
        if let zhipuAdapter { return zhipuAdapter }
        let session = ZhipuUsageAdapter(profileID: account.profileID)
        session.onQuota = { [weak self, weak session] result in
            guard let self, let session, self.zhipuAdapter === session,
                  self.platformAccounts.enabled.contains(.zhipu) else { return false }
            self.zhipuLoading = false
            self.releaseZhipuPermit()
            switch result {
            case .success(let quota):
                self.refreshPolicy.record(nil)
                return self.acceptZhipuQuota(quota)
            case .failure(let failure):
                self.refreshPolicy.record(failure)
                self.zhipuRefreshFailure = failure
                if failure == .authorization {
                    let wasConnected = self.zhipuConnected
                    self.zhipuConnected = false
                    self.zhipuQuota = nil
                    self.zhipuLastUpdated = nil
                    self.zhipuAccountName = nil
                    self.zhipuSigningIn = false
                    self.zhipuError = "请在智谱官方网页完成登录"
                    if wasConnected { self.onAccountsChanged?() }
                } else {
                    self.zhipuUsageError = "智谱额度暂不可用：\(failure.message(for: .zhipu))"
                }
            }
            return false
        }
        session.onAnalysis = { [weak self, weak session] identity, result in
            guard let self, let session, !self.isDisposed, self.zhipuAdapter === session, self.zhipuConnected,
                  self.platformAccounts.enabled.contains(.zhipu),
                  self.accountProfiles.entries(for:.zhipu).first(where: { $0.id == self.account.profileID })?.identity == "customer:" + identity else { return }
            switch result {
            case .success(let snapshot): self.analysis.accept(snapshot)
            case .failure(let error): self.analysis.fail("智谱官方模型日统计暂不可用，已有历史仍保留", failure: .dailyStatisticsFailure(for: error))
            }
            self.objectWillChange.send()
        }
        session.onWindowClosed = { [weak self, weak session] in
            guard let self, let session, self.zhipuAdapter === session,
                  self.platformAccounts.enabled.contains(.zhipu) else { return }
            self.zhipuSigningIn = false
        }
        zhipuAdapter = session
        return session
    }

    @discardableResult
    func acceptZhipuQuota(_ quota: ZhipuQuota) -> Bool {
        guard let owner else { return false }
        let account = activeAccountReference(for: .zhipu)
        guard owner.savedAccounts.contains(account) else { return false }
        if let identity = quota.accountIdentity {
            let key = "customer:" + identity
            let entries = owner.accountProfiles.entries(for: .zhipu)
            if let original = entries.first(where: { $0.id == account.profileID })?.identity, original != key {
                rejectZhipuIdentity(.differentAccount)
                return true
            }
            let matches = entries.filter { $0.id == account.profileID || $0.identity == key }
            if let canonical = matches.first, canonical.id != account.profileID {
                owner.setAccountVisible(account, visible: false)
                rejectZhipuIdentity(.duplicate(label: canonical.label))
                return true
            }
            // Older saved accounts retain ownership even if their identity arrives later.
            for entry in matches where entry.id != account.profileID {
                let duplicate = AccountReference(platform: .zhipu, profileID: entry.id)
                owner.accountProfiles.identify(entry.id, platform: .zhipu, identity: nil)
                owner.setAccountVisible(duplicate, visible: false)
                owner.accountRuntime(for: duplicate).rejectZhipuIdentity(.duplicate(label: owner.accountLabel(account)))
            }
            owner.accountProfiles.identify(account.profileID, platform: .zhipu, identity: key)
            owner.persistProfiles()
        } else if !zhipuConnected || zhipuSigningIn || owner.pendingAutoDisplay.contains(account) {
            zhipuUsageError = "正在确认登录账号身份，请等待网页完成加载；若一直未完成，请刷新登录页。"
            return false
        }
        let wasConnected = zhipuConnected
        authorizationIssue = nil
        zhipuQuota = quota; zhipuConnected = true; zhipuSigningIn = false
        zhipuAccountName = quota.level.map { "智谱 CodingPlan · \($0)" } ?? "智谱 CodingPlan"
        zhipuLastUpdated = .now; zhipuError = nil; zhipuUsageError = nil
        zhipuRefreshFailure = nil
        recordQuotaTrend()
        if !wasConnected {
            accountAuthorizationSucceeded(.zhipu); onAccountsChanged?(); onZhipuConnected?()
        }
        return true
    }

    func rejectZhipuIdentity(_ issue: AccountAuthorizationIssue) {
        authorizationIssue = issue
        let message = issue.localizedDescription
        zhipuRefreshFailure = nil
        zhipuLoading = false; zhipuSigningIn = false; zhipuConnected = false
        zhipuQuota = nil; zhipuLastUpdated = nil; zhipuAccountName = nil
        zhipuError = message; accountManagementError = message
        owner?.accountManagementError = message
    }

    private func clearZhipuState() {
        zhipuLoading = false
        zhipuSigningIn = false
        zhipuConnected = false
        zhipuQuota = nil
        zhipuError = nil
        zhipuUsageError = nil
        zhipuRefreshFailure = nil
        zhipuLastUpdated = nil
        zhipuAccountName = nil
    }

    private func clearDeepSeekState() {
        deepSeekLoginVersion += 1
        if isSigningIn { authFlow.cancel() }
        sessionVersion += 1
        refreshingVersion = nil
        profileRequestVersion = nil
        isLoading = false
        isSigningIn = false
        isAvailable = true
        accountConnected = false
        accountName = nil
        balance = nil
        officialUsage = nil
        usageLastUpdated = nil
        usageError = nil
        deepSeekRefreshFailure = nil
        deepSeekUsageFailure = nil
        lastUpdated = nil
        errorMessage = nil
    }

    private func persistLedger() {
        if let data = try? JSONEncoder().encode(ledger) {
            defaults.set(data, forKey: ledgerStorageKey)
        }
    }

    /// Stop polling without invalidating a token rotation already in flight.
    func pauseAccountPolling() {
        hasStartedPolling = false
        if !isRefreshing { pollTask?.cancel(); pollTask = nil }
    }

    /// Called only when a runtime loses ownership of its account or that account is removed.
    func disposeAccountRuntime() {
        releaseZhipuPermit()
        isDisposed = true
        invalidateHistoryStorage()
        historyObservations.removeAll()
        analysisTask?.cancel(); analysisTask = nil
        pauseAccountPolling()
        clearDeepSeekState(); clearChatGPTState()
        zhipuAdapter?.suspend(); zhipuAdapter = nil; clearZhipuState()
    }
    func quotaResetDate(for metric: UsageMetric) -> Date? {
        quotaWindow(for: metric).resetAt
    }
}
