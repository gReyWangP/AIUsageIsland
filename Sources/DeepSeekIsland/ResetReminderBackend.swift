import EventKit
import Foundation
import UserNotifications

@MainActor
protocol ResetReminderBackend {
    /// 更新同一个预约；切换目标时清理旧预约，失败时保留原预约。
    func put(_ plan: ResetReminderPlan, replacing old: ResetReminderRecord?) async throws -> String?
    func cancel(_ record: ResetReminderRecord) async throws
}
@MainActor
final class SystemResetReminderBackend: ResetReminderBackend {
    private lazy var center = UNUserNotificationCenter.current()
    private lazy var store = EKEventStore()
    static func request(for plan: ResetReminderPlan) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = plan.lead == .atTime ? "ChatGPT · 预计重置时间已到" : "ChatGPT · 距预计重置还有 15 分钟"
        content.body = "预计重置：" + OfficialResetAnnouncement.beijingDate(plan.selectedDate)
            + "。请检查当前账号额度，预约提醒不代表额度已恢复。"
        content.categoryIdentifier = ResetReminderAction.category
        content.userInfo = ["sourceURL": plan.event.sourceURL.absoluteString]
        content.sound = .default
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: plan.notifyAt)
        parts.calendar = calendar; parts.timeZone = calendar.timeZone
        return UNNotificationRequest(identifier: ResetReminderAction.requestID, content: content,
                                     trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
    }
    static func validateDeadline(_ plan: ResetReminderPlan, now: Date = .now) throws {
        guard plan.notifyAt > now.addingTimeInterval(5) else {
            throw ResetReminderError(message: "提醒时间已过或即将到达，请重新选择时间；原预约会保留。")
        }
    }
    private func accessReminders() async throws {
        guard try await store.requestFullAccessToReminders() else {
            throw ResetReminderError(message: "未允许访问提醒事项；原预约会保留，也可以改用预约通知。")
        }
    }
    func put(_ plan: ResetReminderPlan, replacing old: ResetReminderRecord?) async throws -> String? {
        if plan.destination == .notification {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                throw ResetReminderError(message: "系统通知未允许，请在系统通知设置中开启，或选择系统提醒事项。")
            }
            // 清理系统待办前先检查权限；不因拒绝权限而替换有效的原预约。
            if old?.plan.destination == .reminders { try await accessReminders() }
            try Self.validateDeadline(plan)
            try await center.add(Self.request(for: plan))
            if let old, old.plan.destination == .reminders {
                do { try deleteReminder(old) }
                catch { center.removePendingNotificationRequests(withIdentifiers: [ResetReminderAction.requestID]); throw error }
            }
            return nil
        }
        try await accessReminders()
        try Self.validateDeadline(plan)
        let reminder: EKReminder
        if let old, old.plan.destination == .reminders, let id = old.externalID,
           let item = store.calendarItem(withIdentifier: id) as? EKReminder {
            reminder = item
        } else {
            reminder = EKReminder(eventStore: store)
            guard let calendar = store.defaultCalendarForNewReminders() else {
                throw ResetReminderError(message: "系统中没有可写入的提醒事项列表，请先在提醒事项中创建列表。")
            }
            reminder.calendar = calendar
        }
        reminder.title = "检查 ChatGPT 重置额度"
        reminder.notes = "预计重置：" + OfficialResetAnnouncement.beijingDate(plan.selectedDate)
            + "。这是官方预告的预约提醒，不代表账号已恢复。\n" + plan.event.sourceURL.absoluteString
        reminder.url = plan.event.sourceURL
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var due = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: plan.notifyAt)
        due.calendar = calendar; due.timeZone = calendar.timeZone
        reminder.dueDateComponents = due
        reminder.alarms = [EKAlarm(absoluteDate: plan.notifyAt)]
        reminder.isCompleted = false
        try store.save(reminder, commit: true)
        center.removePendingNotificationRequests(withIdentifiers: [ResetReminderAction.requestID])
        center.removeDeliveredNotifications(withIdentifiers: [ResetReminderAction.requestID])
        return reminder.calendarItemIdentifier
    }
    private func deleteReminder(_ record: ResetReminderRecord) throws {
        guard let id = record.externalID, let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        try store.remove(reminder, commit: true)
    }
    func cancel(_ record: ResetReminderRecord) async throws {
        if record.plan.destination == .reminders { try await accessReminders(); try deleteReminder(record) }
        center.removePendingNotificationRequests(withIdentifiers: [ResetReminderAction.requestID])
        center.removeDeliveredNotifications(withIdentifiers: [ResetReminderAction.requestID])
    }
}
