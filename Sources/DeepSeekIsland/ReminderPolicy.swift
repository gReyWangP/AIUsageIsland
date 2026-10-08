import Foundation
import UserNotifications

enum OfficialResetAction {
    static let category = "OFFICIAL_RESET_NEWS"
    static let view = "VIEW_RESET_SOURCE"
    static let remind = "PLAN_RESET_REMINDER"
    static let scheduledCategory = "OFFICIAL_RESET_SCHEDULED"
}

enum UsageNotificationAction {
    static let remind = "PLAN_PERSONAL_QUOTA_REMINDER"
    static let quotaCategory = "USAGE_QUOTA_LOW_APPOINTMENT"
    static let category = "USAGE_QUOTA"
    static let view = "VIEW_USAGE"
    static let snoozeToday = "SNOOZE_USAGE_TODAY"
}

extension IslandSettings {
    func allowsReminder(at now: Date = .now, calendar: Calendar = .current) -> Bool {
        if let until = alertsSnoozedUntil, now < until { return false }
        guard alertsScheduleEnabled else { return true }
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let start = max(0, min(1439, alertStartMinute)), end = max(0, min(1439, alertEndMinute))
        if start == end { return true }
        return start < end ? minute >= start && minute < end : minute >= start || minute < end
    }
    func snoozeRemindersToday(at now: Date = .now, calendar: Calendar = .current) {
        alertsSnoozedUntil = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
    }
}

enum ResetReminderAction {
    static let category = "RESET_APPOINTMENT"
    static let requestID = "reset-appointment-1"
}
