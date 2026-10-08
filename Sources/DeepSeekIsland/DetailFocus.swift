import SwiftUI

struct DetailFocusTarget: Equatable {
    let id = UUID()
    let platform: UsagePlatform
    let rowID: String
    var accountID: String? = nil
    func matches(_ snapshot: PlatformSnapshot, row: String) -> Bool {
        platform == snapshot.platform && rowID == row && (accountID == nil || accountID == snapshot.id)
    }
}

extension View {
    func notificationFocus(_ enabled: Bool) -> some View {
        self.background(enabled ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(enabled ? Color.accentColor : Color.clear, lineWidth: 1.5))
    }
}

extension IslandModel {
    var detailSnapshots: [PlatformSnapshot] {
        if let account = notificationDetailAccount, savedAccounts.contains(account), !visibleAccounts.contains(account) {
            var snapshot = accountRuntime(for: account).snapshot(for: account.platform)
            snapshot.id = account.id; snapshot.title = accountLabel(account)
            return [snapshot]
        }
        return snapshots
    }
    func focusNotification(_ metric: UsageMetric, account: AccountReference? = nil) {
        let account = account ?? activeAccountReference(for: metric.platform)
        guard savedAccounts.contains(account) else { detailFocus = nil; return }
        notificationDetailAccount = visibleAccounts.contains(account) ? nil : account
        let source = accountRuntime(for: account)
        var row = metric == .zhipuWeek ? "week" : "hero"
        if metric.platform == .chatGPT {
            if source.chatGPTQuota?.session?.windowSeconds == metric.windowSeconds { row = "hero" }
            else if source.chatGPTQuota?.weekly?.windowSeconds == metric.windowSeconds { row = "week" }
            else { row = "platform" }
        }
        let target = DetailFocusTarget(platform: metric.platform, rowID: row, accountID: account.id)
        detailFocus = target
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if self?.detailFocus?.id == target.id { self?.detailFocus = nil }
        }
    }
}
