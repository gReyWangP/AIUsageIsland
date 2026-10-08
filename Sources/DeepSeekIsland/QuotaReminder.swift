import Combine
import Foundation
import UserNotifications

struct QuotaReminderPlan: Codable, Equatable {
    let metric: UsageMetric
    let resetAt: Date
    let lead: ResetReminderLead
    var accountKey: String = "legacy"
    var accountLabel: String = ""
    var id: String { metric.rawValue + ":" + accountKey }
    var notifyAt: Date { resetAt.addingTimeInterval(-Double(lead.rawValue)) }
    static func make(metric: UsageMetric, resetAt: Date, lead: ResetReminderLead, accountKey: String = "legacy", accountLabel: String = "", now: Date = .now) throws -> Self {
        let plan = Self(metric: metric, resetAt: resetAt, lead: lead, accountKey: accountKey, accountLabel: accountLabel)
        guard metric != .deepSeekBalance, resetAt.timeIntervalSince1970.isFinite, plan.notifyAt > now.addingTimeInterval(5) else {
            throw ResetReminderError(message: "没有可预约的未来重置时间；提前 15 分钟已过时，请选择到点提醒。")
        }
        return plan
    }
}
extension QuotaReminderPlan {
    enum CodingKeys: String, CodingKey { case metric, resetAt, lead, accountKey, accountLabel }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        metric = try values.decode(UsageMetric.self, forKey: .metric)
        resetAt = try values.decode(Date.self, forKey: .resetAt)
        lead = try values.decode(ResetReminderLead.self, forKey: .lead)
        accountKey = try values.decodeIfPresent(String.self, forKey: .accountKey) ?? "legacy"
        accountLabel = try values.decodeIfPresent(String.self, forKey: .accountLabel) ?? ""
    }
}
@MainActor protocol QuotaReminderBackend {
    func put(_ plan: QuotaReminderPlan) async throws
    func cancel(_ metric: UsageMetric)
    func cancel(_ plan: QuotaReminderPlan)
}
extension QuotaReminderBackend {
    func cancel(_ plan: QuotaReminderPlan) { cancel(plan.metric) }
}
@MainActor final class SystemQuotaReminderBackend: QuotaReminderBackend {
    nonisolated static let category = "PERSONAL_QUOTA_APPOINTMENT"
    private lazy var center = UNUserNotificationCenter.current()
    static func identifier(_ metric: UsageMetric) -> String { "quota-appointment-" + metric.rawValue }
    static func identifier(_ plan: QuotaReminderPlan) -> String {
        identifier(plan.metric) + (plan.accountKey == "legacy" ? "" : ":" + plan.accountKey)
    }
    static func request(for plan: QuotaReminderPlan) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = plan.metric.platform.title + " · " + plan.metric.windowLabel
            + (plan.lead == .atTime ? "预计重置时间已到" : "距预计重置还有 15 分钟")
        content.body = (plan.accountLabel.isEmpty ? "" : "账号：" + plan.accountLabel + "。")
            + "预计重置：" + OfficialResetAnnouncement.beijingDate(plan.resetAt) + "。请查看最新数据；到点不代表额度已恢复。"
        content.sound = .default; content.categoryIdentifier = category
        content.userInfo = ["metric": plan.metric.rawValue, "accountKey": plan.accountKey]
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: plan.notifyAt)
        parts.calendar = calendar; parts.timeZone = calendar.timeZone
        return UNNotificationRequest(identifier: identifier(plan), content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
    }
    func put(_ plan: QuotaReminderPlan) async throws {
        guard try await center.requestAuthorization(options: [.alert, .sound]) else { throw ResetReminderError(message: "未允许系统通知，原预约会保留。") }
        guard plan.notifyAt > Date.now.addingTimeInterval(5) else { throw ResetReminderError(message: "权限确认期间提醒时间已过，请重新选择。") }
        try await center.add(Self.request(for: plan))
    }
    func cancel(_ metric: UsageMetric) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier(metric)])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier(metric)])
    }
    func cancel(_ plan: QuotaReminderPlan) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier(plan)])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier(plan)])
    }
}
@MainActor final class QuotaReminderController: ObservableObject {
    @Published private(set) var accountPlans: [String: QuotaReminderPlan] = [:]
    // Legacy callers without an account context continue to see one plan per metric.
    var plans: [UsageMetric: QuotaReminderPlan] {
        var values: [UsageMetric: QuotaReminderPlan] = [:]
        for plan in accountPlans.values.sorted(by: { $0.id < $1.id }) {
            if values[plan.metric] == nil || plan.accountKey == "legacy" { values[plan.metric] = plan }
        }
        return values
    }
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    var onPresent: ((QuotaReminderPlan) -> Void)?
    var isCurrent: ((QuotaReminderPlan) -> Bool)?
    private var generations: [String: Int] = [:]
    private var savingPlan: QuotaReminderPlan?
    private let defaults: UserDefaults
    private let backend: any QuotaReminderBackend
    private let key = "personalQuotaAppointmentsV2"
    init(defaults: UserDefaults = .standard, backend: any QuotaReminderBackend = SystemQuotaReminderBackend()) {
        self.defaults = defaults; self.backend = backend
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([String: QuotaReminderPlan].self, from: data) {
            accountPlans = saved.filter { $0.key == $0.value.id && $0.value.metric != .deepSeekBalance }
        } else if let data = defaults.data(forKey: "personalQuotaAppointmentsV1"),
                  let saved = try? JSONDecoder().decode([UsageMetric: QuotaReminderPlan].self, from: data) {
            for (metric, plan) in saved where metric == plan.metric && metric != .deepSeekBalance { accountPlans[plan.id] = plan }
            persist()
        }
    }
    func plan(for metric: UsageMetric, accountKey: String) -> QuotaReminderPlan? { accountPlans[metric.rawValue + ":" + accountKey] }
    func present(_ plan: QuotaReminderPlan) { error = nil; onPresent?(plan) }
    func save(_ plan: QuotaReminderPlan) async {
        guard !busy else { return }; busy = true; error = nil; savingPlan = plan
        let version = generations[plan.id, default: 0]
        defer { busy = false; savingPlan = nil }
        do {
            let validated = try QuotaReminderPlan.make(metric: plan.metric, resetAt: plan.resetAt, lead: plan.lead, accountKey: plan.accountKey, accountLabel: plan.accountLabel)
            guard isCurrent?(validated) ?? true else { throw ResetReminderError(message: "账号或重置时间已改变，请重新打开预约。") }
            if accountPlans[plan.id] == validated { return }
            try await backend.put(validated)
            guard version == generations[plan.id, default: 0], isCurrent?(validated) ?? true else {
                backend.cancel(plan); accountPlans.removeValue(forKey: plan.id); persist()
                throw ResetReminderError(message: "账号或数据已改变，已取消这次预约。")
            }
            accountPlans[plan.id] = validated; persist()
        } catch { self.error = error.localizedDescription }
    }
    func cancel(_ plan: QuotaReminderPlan) {
        generations[plan.id, default: 0] += 1; backend.cancel(plan); accountPlans.removeValue(forKey: plan.id); persist()
    }
    func cancel(_ metric: UsageMetric) {
        let matches = accountPlans.values.filter { $0.metric == metric }
        if matches.isEmpty {
            generations[metric.rawValue + ":legacy", default: 0] += 1; backend.cancel(metric)
        } else { for plan in matches { cancel(plan) } }
        if let savingPlan, savingPlan.metric == metric { generations[savingPlan.id, default: 0] += 1 }
    }
    func cancel(platform: UsagePlatform) { for metric in UsageMetric.allCases where metric.platform == platform { cancel(metric) } }
    func cancelMissingAccounts(_ accounts: [AccountReference]) {
        func exists(_ plan: QuotaReminderPlan) -> Bool {
            accounts.contains { $0.platform == plan.metric.platform && $0.notificationKey == plan.accountKey }
        }
        for plan in Array(accountPlans.values) where !exists(plan) { cancel(plan) }
        if let savingPlan, !exists(savingPlan) { generations[savingPlan.id, default: 0] += 1 }
    }
    private func persist() { if let data = try? JSONEncoder().encode(accountPlans) { defaults.set(data, forKey: key) } }
}
