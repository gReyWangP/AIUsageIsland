import AppKit
import Foundation
import Combine
import UserNotifications

/// 低余量／用尽后，必须观察到实际余量增加，才报告恢复。
struct QuotaRecoveryLatch: Codable {
    struct Entry: Codable {
        var remaining: Double
        var resetAt: Date?
        var armed: Bool
        var resetObserved: Bool = false
    }
    private var entries: [String: Entry] = [:]
    mutating func remove(keys: Set<String>) { for key in keys { entries.removeValue(forKey: key) } }
    mutating func seed(key: String, remaining: Double, resetAt: Date?, warning: Double = 20) {
        entries[key] = Entry(remaining: remaining, resetAt: resetAt, armed: remaining < warning)
    }
    mutating func observe(key: String, remaining: Double, resetAt: Date?, at now: Date, warning: Double = 20) -> Bool {
        guard remaining.isFinite, (0...100).contains(remaining) else { return false }
        guard let previous = entries[key] else { seed(key: key, remaining: remaining, resetAt: resetAt, warning: warning); return false }
        let exhausted = previous.remaining <= 0.001
        let increased = remaining > previous.remaining + 0.5 || (exhausted && remaining > 0.001)
        let resetPassed = previous.resetAt.map { now >= $0 } ?? false
        // 平台可能先滚动重置时间、随后才返回新额度，保留已到期的等待状态。
        let resetObserved = previous.resetObserved || (previous.armed && resetPassed)
        let send = previous.armed && increased && (resetObserved || exhausted)
        let newWindow = resetAt.map { date in previous.resetAt.map { date > $0 } ?? false } ?? false
        var armed = previous.armed
        if send { armed = false }
        else if remaining < warning && (previous.remaining >= warning || remaining <= 0.001 || newWindow) { armed = true }
        entries[key] = Entry(remaining: remaining, resetAt: resetAt ?? previous.resetAt,
                             armed: armed, resetObserved: send ? false : resetObserved)
        return send
    }
}

struct UsageAlertLatch: Codable {
    struct Entry: Codable {
        var level: Int
        var lastNotified: Date?
        var lastNotifiedLevel: Int = 0
        var notifiedResetAt: Date? = nil
        var observedResetAt: Date? = nil
    }
    private var entries: [String: Entry] = [:]
    mutating func remove(keys: Set<String>) { for key in keys { entries.removeValue(forKey: key) } }
    mutating func seed(key: String, severity: Int) {
        var entry = entries[key] ?? Entry(level: severity)
        entry.level = severity
        entries[key] = entry
    }
    mutating func observe(key: String, severity: Int, at now: Date, canNotify: Bool = true, recordNotification: Bool = true, resetAt: Date? = nil) -> Bool {
        guard var entry = entries[key] else { seed(key: key, severity: severity); return false }
        let crossed = severity > entry.level && severity > 0
        entry.level = severity
        let nextWindow = resetAt.map { date in entry.notifiedResetAt.map { date > $0 } ?? false } ?? false
        let cooled = nextWindow || (entry.lastNotified.map { now.timeIntervalSince($0) >= 1800 } ?? true)
        let escalated = severity > entry.lastNotifiedLevel
        let send = canNotify && crossed && (cooled || escalated)
        if send && recordNotification { entry.lastNotified = now; entry.lastNotifiedLevel = severity }
        entries[key] = entry
        return send
    }
    func canNotify(key: String, severity: Int, at now: Date, resetAt: Date? = nil) -> Bool {
        guard let entry = entries[key] else { return true }
        let nextWindow = resetAt.map { date in entry.notifiedResetAt.map { date > $0 } ?? false } ?? false
        return nextWindow || (entry.lastNotified.map { now.timeIntervalSince($0) >= 1800 } ?? true)
            || severity > entry.lastNotifiedLevel
    }
    /// 记录已观察窗口；旧版本没有周期字段时先采用当前周期，避免重复或永久静默。
    mutating func observeWindow(key: String, resetAt: Date?) -> Bool {
        guard var entry = entries[key], let resetAt else { return false }
        let previous = entry.observedResetAt ?? entry.notifiedResetAt
        if entry.lastNotified != nil && entry.notifiedResetAt == nil { entry.notifiedResetAt = resetAt }
        entry.observedResetAt = resetAt
        entries[key] = entry
        return previous.map { resetAt > $0 } ?? false
    }
    /// 初次拿到当前额度也可提醒；发送成功后按窗口和等级持久去重。
    func canNotifyInitially(key: String, severity: Int, resetAt: Date?) -> Bool {
        guard severity > 0 else { return false }
        guard let entry = entries[key], entry.lastNotified != nil else { return true }
        if let resetAt, let previous = entry.notifiedResetAt, resetAt > previous { return true }
        return severity > entry.lastNotifiedLevel
    }
    mutating func recordNotification(key: String, severity: Int, at now: Date, resetAt: Date? = nil) {
        var entry = entries[key] ?? Entry(level: severity)
        entry.lastNotified = now; entry.lastNotifiedLevel = severity
        entry.notifiedResetAt = resetAt ?? entry.notifiedResetAt
        entries[key] = entry
    }

}

struct UsageAlertMessage: Sendable {
    let metric: String
    let title: String
    let body: String
    let recovered: Bool
    let sourceURL: URL?
    let accountKey: String?
    let announcement: OfficialResetAnnouncement?
    init(metric: String, title: String, body: String, recovered: Bool = false, sourceURL: URL? = nil, announcement: OfficialResetAnnouncement? = nil, accountKey: String? = nil) {
        self.accountKey = accountKey; self.metric = metric; self.title = title; self.body = body; self.recovered = recovered; self.sourceURL = sourceURL; self.announcement = announcement
    }
}
@MainActor
protocol UsageNotificationBackend {
    func authorize() async throws -> Bool
    func permissionText() async -> String
    func deliver(_ message: UsageAlertMessage) async throws
    func installDelegate(_ delegate: any UNUserNotificationCenterDelegate)
    func clearNotifications()
    func discard(metric: String)
    func discard(metric: String, accountKey: String?)
}
extension UsageNotificationBackend {
    func installDelegate(_ delegate: any UNUserNotificationCenterDelegate) {}
    func clearNotifications() {}
    func discard(metric: String) {}
    func discard(metric: String, accountKey: String?) { discard(metric: metric) }
}
@MainActor
final class SystemUsageNotifications: UsageNotificationBackend {
    private let center = UNUserNotificationCenter.current()
    func installDelegate(_ delegate: any UNUserNotificationCenterDelegate) {
        center.delegate = delegate
        center.setNotificationCategories([Self.category(), Self.quotaCategory(), Self.officialCategory(), Self.officialScheduledCategory(), Self.appointmentCategory(), Self.quotaAppointmentCategory()])
    }
    static func category() -> UNNotificationCategory {
        let view = UNNotificationAction(identifier: UsageNotificationAction.view, title: "查看额度", options: [.foreground])
        let snooze = UNNotificationAction(identifier: UsageNotificationAction.snoozeToday, title: "今天暂不提醒", options: [])
        return UNNotificationCategory(identifier: UsageNotificationAction.category,
            actions: [view, snooze], intentIdentifiers: [], options: [])
    }

    static func quotaCategory() -> UNNotificationCategory {
        UNNotificationCategory(identifier: UsageNotificationAction.quotaCategory,
            actions: [UNNotificationAction(identifier: UsageNotificationAction.view, title: "查看额度", options: [.foreground]),
                UNNotificationAction(identifier: UsageNotificationAction.remind, title: "重置时提醒我", options: [.foreground]),
                UNNotificationAction(identifier: UsageNotificationAction.snoozeToday, title: "今天暂不提醒", options: [])], intentIdentifiers: [], options: [])
    }
    static func quotaAppointmentCategory() -> UNNotificationCategory {
        UNNotificationCategory(identifier: SystemQuotaReminderBackend.category,
            actions: [UNNotificationAction(identifier: UsageNotificationAction.view, title: "查看额度", options: [.foreground])], intentIdentifiers: [], options: [])
    }
    static func officialCategory() -> UNNotificationCategory {
        let view = UNNotificationAction(identifier: OfficialResetAction.view, title: "查看原帖", options: [.foreground])
        let snooze = UNNotificationAction(identifier: UsageNotificationAction.snoozeToday, title: "今天暂不提醒", options: [])
        return UNNotificationCategory(identifier: OfficialResetAction.category, actions: [view, snooze], intentIdentifiers: [], options: [])
    }
    static func officialScheduledCategory() -> UNNotificationCategory {
        let view = UNNotificationAction(identifier: OfficialResetAction.view, title: "查看原帖", options: [.foreground])
        let remind = UNNotificationAction(identifier: OfficialResetAction.remind, title: "到时提醒我", options: [.foreground])
        let snooze = UNNotificationAction(identifier: UsageNotificationAction.snoozeToday, title: "今天暂不提醒", options: [])
        return UNNotificationCategory(identifier: OfficialResetAction.scheduledCategory, actions: [view, remind, snooze], intentIdentifiers: [], options: [])
    }
    static func appointmentCategory() -> UNNotificationCategory {
        let view = UNNotificationAction(identifier: UsageNotificationAction.view, title: "查看额度", options: [.foreground])
        let source = UNNotificationAction(identifier: OfficialResetAction.view, title: "查看原帖", options: [.foreground])
        return UNNotificationCategory(identifier: ResetReminderAction.category, actions: [view, source], intentIdentifiers: [], options: [])
    }
    func clearNotifications() {
        // 当天静默只清除自动提醒，不取消用户主动预约的到点通知。
        Task {
            let delivered = await center.deliveredNotifications()
            center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request.identifier).filter { $0.hasPrefix("usage-") })
            let pending = await center.pendingNotificationRequests()
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix("usage-") })
        }
    }
    func discard(metric: String) {
        center.removeDeliveredNotifications(withIdentifiers: ["usage-" + metric])
        center.removePendingNotificationRequests(withIdentifiers: ["usage-" + metric])
    }
    func authorize() async throws -> Bool { try await center.requestAuthorization(options: [.alert]) }
    func permissionText() async -> String {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .denied: return "系统通知已关闭；请在系统设置中开启"
        case .notDetermined: return "尚未申请系统通知权限"
        case .provisional: return "系统仅允许静默通知；需要完整通知授权"
        case .authorized, .ephemeral:
            let style = settings.alertStyle == .banner ? "临时横幅" : settings.alertStyle == .alert ? "持续横幅" : "无横幅"
            return "通知已允许 · 桌面提醒\(settings.alertSetting == .enabled ? "开启" : "关闭") · \(style)"
        @unknown default: return "通知权限暂不可用"
        }
    }
    func deliver(_ message: UsageAlertMessage) async throws {
        try await center.add(UNNotificationRequest(identifier: Self.identifier(metric: message.metric, accountKey: message.accountKey), content: Self.content(message), trigger: nil))
    }
    static func identifier(metric: String, accountKey: String?) -> String {
        "usage-" + metric + (accountKey.map { ":" + $0 } ?? "")
    }
    func discard(metric: String, accountKey: String?) {
        let id = Self.identifier(metric: metric, accountKey: accountKey)
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }
    static func content(_ message: UsageAlertMessage) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = message.title; content.body = message.body
        content.userInfo = ["metric": message.metric, "recovered": message.recovered]
        if let accountKey = message.accountKey { content.userInfo["accountKey"] = accountKey }
        content.categoryIdentifier = !message.recovered && message.metric != UsageMetric.deepSeekBalance.rawValue ? UsageNotificationAction.quotaCategory : UsageNotificationAction.category
        if let url = message.sourceURL, OfficialResetAnnouncement.validSource(url) {
            content.userInfo["sourceURL"] = url.absoluteString
            content.categoryIdentifier = OfficialResetAction.category
            if let event = message.announcement, event.phase == .scheduled, !event.reminderDates.isEmpty,
               let json = event.notificationJSON {
                content.userInfo["resetEventJSON"] = json
                content.categoryIdentifier = OfficialResetAction.scheduledCategory
            }
        }
        return content
    }
}

@MainActor
final class UsageAlertsController: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    let barkPush = BarkPushService()
    @Published private(set) var permissionText = "开启后申请系统通知权限"
    @Published private(set) var changing = false
    @Published private(set) var lastError: String?
    private let model: IslandModel
    private let settings: IslandSettings
    private let onOpen: () -> Void
    var onOpenMetric: ((UsageMetric) -> Void)?
    var onOpenAccountMetric: ((AccountReference, UsageMetric) -> Void)?
    var onOpenAnnouncement: ((URL) -> Void)?
    let officialResets: OfficialResetMonitor
    let resetReminders: ResetReminderController
    let quotaReminders: QuotaReminderController
    private var officialDeliveryVersion = 0
    private let defaults: UserDefaults
    private let backend: any UsageNotificationBackend
    private var latch: UsageAlertLatch
    private var recoveryLatch: QuotaRecoveryLatch
    private var subscriptions = Set<AnyCancellable>()
    private var lastEnabled: Bool
    private var selectedMetrics: Set<UsageMetric>
    private var connectedMetrics = Set<String>()
    private var previousAccountPolicies: [String: AccountAlertPolicy] = [:]
    private var pendingBaselines = Set<UsageMetric>()
    private var pendingAccountBaselines = Set<String>()
    private struct PendingAlert {
        let metric: UsageMetric
        let message: UsageAlertMessage
        let severity: Int
        let generation: Int
        let initial: Bool
        let resetAt: Date?
        let accountKey: String
        let account: AccountReference
    }
    private var deliveryVersions: [String: Int] = [:]
    private var queuedAlerts: [String: PendingAlert] = [:]
    private var deliveryTask: Task<Void, Never>?
    private let storageKey = "usageAlertLatchV1"

    init(model: IslandModel, settings: IslandSettings, onOpen: @escaping () -> Void, defaults: UserDefaults = .standard, backend: any UsageNotificationBackend = SystemUsageNotifications(), quotaReminderBackend: any QuotaReminderBackend = SystemQuotaReminderBackend()) {
        self.model = model; self.settings = settings; self.onOpen = onOpen; self.defaults = defaults
        self.backend = backend
        officialResets = OfficialResetMonitor(settings: settings, model: model, defaults: defaults)
        resetReminders = ResetReminderController(defaults: defaults)
        quotaReminders = QuotaReminderController(defaults: defaults, backend: quotaReminderBackend)
        latch = defaults.data(forKey: "usageAlertLatchV1").flatMap { try? JSONDecoder().decode(UsageAlertLatch.self, from: $0) } ?? UsageAlertLatch()
        recoveryLatch = defaults.data(forKey: "quotaRecoveryLatchV1").flatMap { try? JSONDecoder().decode(QuotaRecoveryLatch.self, from: $0) } ?? QuotaRecoveryLatch()
        lastEnabled = settings.alertsEnabled
        selectedMetrics = settings.alertMetrics
        super.init()
        backend.installDelegate(self)
        model.onAccountRemoved = { [weak self] account in self?.accountRemoved(account) }
        officialResets.onNotice = { [weak self] message in await self?.deliverOfficialAnnouncement(message) }
        let officialPolicies: [AnyPublisher<Void, Never>] = [
            settings.$officialResetAlertsEnabled.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$alertsScheduleEnabled.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$alertStartMinute.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$alertEndMinute.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$alertsSnoozedUntil.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()]
        Publishers.MergeMany(officialPolicies).sink { [weak self] in self?.officialDeliveryVersion += 1 }.store(in: &subscriptions)
        model.objectWillChange.merge(with: settings.objectWillChange).receive(on: RunLoop.main)
            .sink { [weak self] in self?.evaluate() }.store(in: &subscriptions)
        let policies: [AnyPublisher<Void, Never>] = [
            settings.$alertsEnabled.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$alertsScheduleEnabled.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$alertStartMinute.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$alertEndMinute.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$alertsSnoozedUntil.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()]
        Publishers.MergeMany(policies).sink { [weak self] in
            self?.invalidateNotifications()
        }.store(in: &subscriptions)
        settings.$alertThresholds.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.invalidateNotifications(recovered: false)
            if let self { self.pendingBaselines.formUnion(self.settings.alertMetrics) }
        }.store(in: &subscriptions)
        settings.$lowAlertsEnabled.removeDuplicates().dropFirst().sink { [weak self] enabled in
            self?.invalidateNotifications(recovered: false)
            if enabled, let self { self.pendingBaselines.formUnion(self.settings.alertMetrics) }
        }.store(in: &subscriptions)
        settings.$recoveryAlertsEnabled.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.invalidateNotifications(recovered: true)
        }.store(in: &subscriptions)
        settings.$alertMetrics.removeDuplicates().dropFirst().sink { [weak self] selected in
            guard let self else { return }
            self.invalidateNotifications(metrics: self.settings.alertMetrics.subtracting(selected))
        }.store(in: &subscriptions)
        Task { await updatePermission() }
    }

    func setAccountEnabled(_ account: AccountReference, enabled: Bool) async {
        if enabled { await setEnabled(true); guard settings.alertsEnabled else { return } }
        var policy = settings.reminderPolicy(for: account, model: model)
        policy.enabled = enabled; settings.setReminderPolicy(policy, for: account)
        model.reconcileAccountRuntimes()
    }

    func setEnabled(_ enabled: Bool) async {
        guard !changing else { return }
        changing = true
        defer { changing = false }
        lastError = nil
        if enabled {
            do {
                let granted = try await backend.authorize()
                let addresses = BarkPushService.addresses(settings.barkPushAddress)
                let barkReady = settings.barkPushEnabled && !addresses.isEmpty
                    && addresses.allSatisfy { (try? BarkPushService.request(address: $0, title: "", body: "")) != nil }
                settings.alertsEnabled = granted || barkReady
                if !granted && !barkReady { lastError = "系统未允许通知，请在系统设置中开启 AIUsageIsland 的通知。" }
            } catch {
                settings.alertsEnabled = false
                lastError = "无法申请通知权限：\(error.localizedDescription)"
            }
        } else {
            settings.alertsEnabled = false
        }
        await updatePermission()
    }

    func updatePermission() async { permissionText = await backend.permissionText() }

    func evaluate() {
        let enabling = settings.alertsEnabled && !lastEnabled
        lastEnabled = settings.alertsEnabled
        let previousSelection = selectedMetrics
        selectedMetrics = settings.alertMetrics
        if enabling { pendingBaselines.formUnion(selectedMetrics) }
        pendingBaselines.formUnion(selectedMetrics.subtracting(previousSelection))
        let baselineMetrics = pendingBaselines
        var valid = Set<String>()
        for account in model.savedAccounts {
            let policy = settings.reminderPolicy(for: account, model: model)
            let previous = previousAccountPolicies[account.id]
            let changed = previous != nil && previous != policy
            if let previous, changed {
                pendingAccountBaselines.formUnion(policy.metrics.map(account.alertKey))
                if previous.enabled != policy.enabled || previous.metrics != policy.metrics || previous.thresholds != policy.thresholds {
                    invalidateNotifications(account: account)
                } else {
                    if previous.lowEnabled != policy.lowEnabled { invalidateNotifications(recovered: false, account: account) }
                    if previous.recoveryEnabled != policy.recoveryEnabled { invalidateNotifications(recovered: true, account: account) }
                }
            }
            previousAccountPolicies[account.id] = policy
            let source = model.accountRuntime(for: account)
            guard source.freshness(for: account.platform).allowsAlerts else { continue }
            for metric in UsageMetric.allCases where metric.platform == account.platform {
                let key = account.alertKey(metric), data = source.usageReading(for: metric)
                guard let severity = policy.thresholds(for: metric).severity(data) else { continue }
                valid.insert(key)
                let date = resetDate(for: metric, source: source)
                let newWindow = latch.observeWindow(key: key, resetAt: date)
                let seed = changed || pendingAccountBaselines.contains(key) || enabling || baselineMetrics.contains(metric) || !settings.alertsEnabled
                    || !policy.enabled || !policy.metrics.contains(metric) || !connectedMetrics.contains(key)
                if seed {
                    latch.seed(key: key, severity: severity)
                    if case .quota(let remaining, _) = data {
                        recoveryLatch.seed(key: key, remaining: remaining, resetAt: date, warning: policy.thresholds(for: metric).warning)
                    }
                    if policy.metrics.contains(metric), reminderIsAllowed(recovered: false, account: account),
                       latch.canNotifyInitially(key: key, severity: severity, resetAt: date) {
                        deliver(metric, account: account, source: source, data: data, initial: true)
                    }
                } else if policy.metrics.contains(metric) {
                    let crossed = latch.observe(key: key, severity: severity, at: .now,
                        canNotify: reminderIsAllowed(recovered: false, account: account), recordNotification: false, resetAt: date)
                    if reminderIsAllowed(recovered: false, account: account), severity > 0, crossed || newWindow {
                        deliver(metric, account: account, source: source, data: data)
                    }
                    if case .quota(let remaining, _) = data,
                       recoveryLatch.observe(key: key, remaining: remaining, resetAt: date, at: .now, warning: policy.thresholds(for: metric).warning),
                       reminderIsAllowed(recovered: true, account: account) {
                        deliver(metric, account: account, source: source, data: data, recovered: true)
                    }
                }
            }
        }
        pendingBaselines.subtract(baselineMetrics.filter { metric in valid.contains(where: { $0 == metric.rawValue || $0.hasPrefix(metric.rawValue + ":") }) })
        pendingAccountBaselines.subtract(valid)
        connectedMetrics = connectedMetrics.filter { key in
            model.savedAccounts.contains { account in
                model.accountRuntime(for: account).hasConnectedAccount(for: account.platform)
                    && UsageMetric.allCases.contains { $0.platform == account.platform && account.alertKey($0) == key }
            }
        }.union(valid)
        previousAccountPolicies = previousAccountPolicies.filter { model.accountReference(id: $0.key) != nil }
        quotaReminders.cancelMissingAccounts(model.savedAccounts)
        if let data = try? JSONEncoder().encode(latch) { defaults.set(data, forKey: storageKey) }
        if let data = try? JSONEncoder().encode(recoveryLatch) { defaults.set(data, forKey: "quotaRecoveryLatchV1") }
    }

    private func resetDate(for metric: UsageMetric, source: AccountRuntime? = nil) -> Date? {
        let source = source ?? model.selectedRuntime(for: metric.platform)
        return source.quotaWindow(for: metric).resetAt
    }

    private func deliver(_ metric: UsageMetric, account: AccountReference, source: AccountRuntime, data: UsageReading, recovered: Bool = false, initial: Bool = false) {
        let policy = settings.reminderPolicy(for: account, model: model)
        let severity = policy.thresholds(for: metric).severity(data) == 2 ? 2 : 1
        let message = UsageAlertMessage(metric: metric.rawValue,
            title: recovered ? metric.platform.title + " · " + metric.windowLabel + "额度已恢复" : metric.title + (severity == 2 ? "严重偏低" : "偏低"),
            body: "账号：" + model.accountLabel(account) + "。" + (recovered ? source.quotaRecoveryContext(for: metric) : "") + data.description + "。点击查看详情。",
            recovered: recovered, accountKey: account.notificationKey)
        queuedAlerts[account.alertKey(metric)] = PendingAlert(metric: metric, message: message, severity: severity,
            generation: deliveryVersion(metric: metric, recovered: recovered, account: account), initial: initial,
            resetAt: resetDate(for: metric, source: source), accountKey: account.notificationKey, account: account)
        if deliveryTask == nil { deliveryTask = Task { @MainActor [weak self] in await self?.flushNotifications() } }
    }
    private func deliveryKey(metric: UsageMetric, recovered: Bool, account: AccountReference) -> String {
        account.alertKey(metric) + (recovered ? ":recovery" : ":low")
    }
    private func deliveryVersion(metric: UsageMetric, recovered: Bool, account: AccountReference) -> Int {
        deliveryVersions[deliveryKey(metric: metric, recovered: recovered, account: account)] ?? 0
    }
    private func invalidateNotifications(metrics: Set<UsageMetric> = Set(UsageMetric.allCases), recovered: Bool? = nil, account: AccountReference? = nil) {
        let accounts = account.map { [$0] } ?? Array(Set(model.savedAccounts + queuedAlerts.values.map(\.account)))
        for account in accounts {
            for metric in metrics where metric.platform == account.platform {
                for kind in [false, true] where recovered == nil || recovered == kind {
                    deliveryVersions[deliveryKey(metric: metric, recovered: kind, account: account), default: 0] += 1
                }
            }
        }
        queuedAlerts = queuedAlerts.filter { _, pending in
            (account != nil && pending.account != account) || !metrics.contains(pending.metric)
                || (recovered != nil && recovered != pending.message.recovered)
        }
    }
    private func initialAlertIsCurrent(_ pending: PendingAlert) -> Bool {
        guard model.savedAccounts.contains(pending.account) else { return false }
        let source = model.accountRuntime(for: pending.account)
        return source.freshness(for: pending.metric.platform).allowsAlerts
            && resetDate(for: pending.metric, source: source) == pending.resetAt
            && settings.reminderPolicy(for: pending.account, model: model).thresholds(for: pending.metric)
                .severity(source.usageReading(for: pending.metric)) == pending.severity
    }
    private func pendingIsAllowed(_ pending: PendingAlert) -> Bool {
        model.savedAccounts.contains(pending.account)
            && pending.generation == deliveryVersion(metric: pending.metric, recovered: pending.message.recovered, account: pending.account)
            && settings.reminderPolicy(for: pending.account, model: model).metrics.contains(pending.metric)
            && reminderIsAllowed(recovered: pending.message.recovered, account: pending.account)
    }
    private func deliverUsageMessage(_ pending: PendingAlert) async throws {
        let message = pending.message
        var delivered = false
        var failure: Error?
        do { try await backend.deliver(message); delivered = true }
        catch { failure = error }
        if settings.barkPushEnabled && pendingIsAllowed(pending)
            && (!pending.initial || initialAlertIsCurrent(pending)) {
            do {
                try await barkPush.sendAll(addresses: settings.barkPushAddress, title: message.title, body: message.body) { address in
                    self.settings.barkPushEnabled && self.pendingIsAllowed(pending)
                        && (!pending.initial || self.initialAlertIsCurrent(pending))
                        && BarkPushService.addresses(self.settings.barkPushAddress).contains(address)
                }
                delivered = true
            } catch {
                failure = error
                lastError = error.localizedDescription
            }
        }
        // A successful channel consumes the event, preventing duplicate local alerts
        // when the remote channel fails. No automatic resend of accepted pushes.
        if !delivered { throw failure ?? BarkPushError("提醒未发送") }
    }
    private func flushNotifications() async {
        while let key = queuedAlerts.keys.sorted().first, let pending = queuedAlerts.removeValue(forKey: key) {
            guard pendingIsAllowed(pending) else { continue }
            if pending.initial {
                guard initialAlertIsCurrent(pending), latch.canNotifyInitially(key: key, severity: pending.severity, resetAt: pending.resetAt) else { continue }
            } else if !pending.message.recovered && !latch.canNotify(key: key, severity: pending.severity, at: .now, resetAt: pending.resetAt) { continue }
            if !pending.message.recovered, pending.resetAt != nil,
               !latch.canNotifyInitially(key: key, severity: pending.severity, resetAt: pending.resetAt) { continue }
            do {
                try await deliverUsageMessage(pending)
                guard pendingIsAllowed(pending), !pending.initial || initialAlertIsCurrent(pending) else {
                    backend.discard(metric: pending.message.metric, accountKey: pending.accountKey); continue
                }
                if !pending.message.recovered {
                    latch.recordNotification(key: key, severity: pending.severity, at: .now, resetAt: pending.resetAt)
                    if let data = try? JSONEncoder().encode(latch) { defaults.set(data, forKey: storageKey) }
                }
            } catch { lastError = "通知未发送：\(error.localizedDescription)" }
        }
        deliveryTask = nil
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let category = notification.request.content.categoryIdentifier
        let allowed: Bool
        if [ResetReminderAction.category, SystemQuotaReminderBackend.category].contains(category) {
            allowed = true
        } else if [OfficialResetAction.category, OfficialResetAction.scheduledCategory].contains(category) {
            allowed = await officialReminderIsAllowed()
        } else {
            let recovered = notification.request.content.userInfo["recovered"] as? Bool ?? false
            let metric = (notification.request.content.userInfo["metric"] as? String).flatMap(UsageMetric.init(rawValue:))
            let key = notification.request.content.userInfo["accountKey"] as? String
            allowed = await notificationIsAllowed(metric: metric, accountKey: key, recovered: recovered)
        }
        return allowed ? [.banner, .list] : []
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        if response.notification.request.content.categoryIdentifier == SystemQuotaReminderBackend.category {
            let metric = (response.notification.request.content.userInfo["metric"] as? String).flatMap(UsageMetric.init(rawValue:))
            let key = response.notification.request.content.userInfo["accountKey"] as? String
            await handleAccountNotificationAction(UsageNotificationAction.view, metric: metric, accountKey: key)
            return
        }
        if response.notification.request.content.categoryIdentifier == ResetReminderAction.category {
            if response.actionIdentifier == OfficialResetAction.view {
                let source = (response.notification.request.content.userInfo["sourceURL"] as? String).flatMap(URL.init(string:))
                await handleOfficialAction(response.actionIdentifier, sourceURL: source)
            } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier || response.actionIdentifier == UsageNotificationAction.view {
                await openDetails(metric: nil)
            }
            return
        }
        if [OfficialResetAction.category, OfficialResetAction.scheduledCategory].contains(response.notification.request.content.categoryIdentifier) {
            if response.actionIdentifier == OfficialResetAction.remind {
                let json = response.notification.request.content.userInfo["resetEventJSON"] as? String
                if let event = OfficialResetAnnouncement.fromNotificationJSON(json) { await resetReminders.present(event) }
                return
            }
            let source = (response.notification.request.content.userInfo["sourceURL"] as? String).flatMap(URL.init(string:))
            await handleOfficialAction(response.actionIdentifier, sourceURL: source)
            return
        }
        let metric = (response.notification.request.content.userInfo["metric"] as? String).flatMap(UsageMetric.init(rawValue:))
        let account = response.notification.request.content.userInfo["accountKey"] as? String
        await handleAccountNotificationAction(response.actionIdentifier, metric: metric, accountKey: account)
    }
    func notificationIsAllowed(metric: UsageMetric?, accountKey: String?, recovered: Bool) -> Bool {
        guard let metric, let accountKey else { return reminderIsAllowed(recovered: recovered) }
        guard let account = model.accountReference(platform: metric.platform, notificationKey: accountKey) else { return false }
        return settings.reminderPolicy(for: account, model: model).metrics.contains(metric)
            && reminderIsAllowed(recovered: recovered, account: account)
    }
    func handleAccountNotificationAction(_ action: String, metric: UsageMetric?, accountKey: String?) {
        guard let metric, let accountKey else { handleNotificationAction(action, metric: metric); return }
        if action == UsageNotificationAction.snoozeToday { handleNotificationAction(action, metric: nil); return }
        guard let account = model.accountReference(platform: metric.platform, notificationKey: accountKey) else { onOpen(); return }
        if action == UsageNotificationAction.remind { reserveQuotaReminder(metric, account: account) }
        else if action == UNNotificationDefaultActionIdentifier || action == UsageNotificationAction.view { openDetails(metric: metric, account: account) }
    }
    func isCurrentAccount(metric: UsageMetric, key: String) -> Bool { model.activeAccountKey(for: metric.platform) == key }
    func accountRemoved(_ account: AccountReference) {
        invalidateNotifications(account: account)
        let metrics = UsageMetric.allCases.filter { $0.platform == account.platform }
        let keys = Set(metrics.map(account.alertKey))
        latch.remove(keys: keys); recoveryLatch.remove(keys: keys); connectedMetrics.subtract(keys)
        pendingAccountBaselines.subtract(keys)
        previousAccountPolicies.removeValue(forKey: account.id)
        if settings.accountReminderPolicies[account.id] != nil { settings.accountReminderPolicies.removeValue(forKey: account.id) }
        for metric in metrics { backend.discard(metric: metric.rawValue, accountKey: account.notificationKey) }
        for plan in Array(quotaReminders.accountPlans.values) where plan.metric.platform == account.platform && plan.accountKey == account.notificationKey {
            quotaReminders.cancel(plan)
        }
        if let data = try? JSONEncoder().encode(latch) { defaults.set(data, forKey: storageKey) }
        if let data = try? JSONEncoder().encode(recoveryLatch) { defaults.set(data, forKey: "quotaRecoveryLatchV1") }
    }
    func accountContextChanged(_ platform: UsagePlatform) {
        let account = model.activeAccountReference(for: platform)
        // Account-scoped reminders follow the saved account, independently of display selection.
        if !settings.accountRemindersMigrated && settings.accountReminderPolicies[account.id] == nil {
            invalidateNotifications(account: account)
            for metric in UsageMetric.allCases where metric.platform == platform {
                connectedMetrics.remove(account.alertKey(metric))
            }
        }
        quotaReminders.cancelMissingAccounts(model.savedAccounts)
    }
    func officialReminderIsAllowed() -> Bool {
        settings.officialResetAlertsEnabled && settings.allowsReminder()
    }
    func requestOfficialPermission() async {
        do { _ = try await backend.authorize(); await updatePermission() }
        catch { lastError = "无法申请通知权限：\(error.localizedDescription)" }
    }
    func deliverOfficialAnnouncement(_ message: UsageAlertMessage) async {
        guard officialReminderIsAllowed(), let url = message.sourceURL, OfficialResetAnnouncement.validSource(url) else { return }
        let version = officialDeliveryVersion
        defer {
            if !officialReminderIsAllowed() || version != officialDeliveryVersion {
                backend.discard(metric: message.metric)
            }
        }
        do {
            // 只在真实的新公告需要通知时申请；不改变账号额度提醒的独立开关。
            let granted = (try? await backend.authorize()) ?? false
            await updatePermission()
            guard officialReminderIsAllowed(), version == officialDeliveryVersion else { return }
            var delivered = false
            if granted {
                do { try await backend.deliver(message); delivered = true }
                catch { lastError = "系统公告通知未发送" }
            }
            if settings.barkPushEnabled, officialReminderIsAllowed(), version == officialDeliveryVersion {
                try await barkPush.sendAll(addresses: settings.barkPushAddress, title: message.title,
                    body: "推送原因：发现新的重置公告或公告状态变化。\n\n"
                        + (message.announcement?.pushSummary ?? message.body + "\n原帖：" + url.absoluteString)) { address in
                        self.settings.barkPushEnabled && self.officialReminderIsAllowed()
                            && version == self.officialDeliveryVersion
                            && BarkPushService.addresses(self.settings.barkPushAddress).contains(address)
                    }
                delivered = true
            }
            guard delivered else { return }
        } catch { lastError = "公告通知未发送：\(error.localizedDescription)" }
    }
    func handleOfficialAction(_ action: String, sourceURL: URL?) {
        if action == UsageNotificationAction.snoozeToday {
            handleNotificationAction(action, metric: nil)
        } else if action == UNNotificationDefaultActionIdentifier || action == OfficialResetAction.view,
                  let url = sourceURL, OfficialResetAnnouncement.validSource(url) {
            if let onOpenAnnouncement { onOpenAnnouncement(url) } else { NSWorkspace.shared.open(url) }
        }
    }
    private func reminderIsAllowed(recovered: Bool, account: AccountReference? = nil) -> Bool {
        guard settings.alertsEnabled && settings.allowsReminder() else { return false }
        if let account {
            let policy = settings.reminderPolicy(for: account, model: model)
            return policy.enabled && (recovered ? policy.recoveryEnabled : policy.lowEnabled)
        }
        return recovered ? settings.recoveryAlertsEnabled : settings.lowAlertsEnabled
    }
    func handleNotificationAction(_ action: String, metric: UsageMetric?) {
        switch action {
        case UsageNotificationAction.remind:
            if let metric { reserveQuotaReminder(metric) }
        case UsageNotificationAction.snoozeToday:
            settings.snoozeRemindersToday()
            backend.clearNotifications()
        case UNNotificationDefaultActionIdentifier, UsageNotificationAction.view:
            openDetails(metric: metric)
        default: break
        }
    }
    func reserveQuotaReminder(_ metric: UsageMetric, account: AccountReference? = nil) {
        let account = account ?? model.activeAccountReference(for: metric.platform)
        let source = model.accountRuntime(for: account)
        guard model.savedAccounts.contains(account), source.freshness(for: metric.platform).allowsAlerts,
              let date = resetDate(for: metric, source: source), let plan = try? QuotaReminderPlan.make(metric: metric, resetAt: date, lead: .atTime,
                accountKey: account.notificationKey, accountLabel: model.accountLabel(account)) else {
            lastError = "当前没有有效的未来重置时间，请刷新额度后再预约。"; openDetails(metric: metric, account: account); return
        }
        quotaReminders.present(plan)
    }
    func openDetails(metric: UsageMetric?, account: AccountReference? = nil) {
        if let metric, let account, let onOpenAccountMetric { onOpenAccountMetric(account, metric) }
        else if let metric, let onOpenMetric { onOpenMetric(metric) } else { onOpen() }
    }
}
