import Foundation

/// 添加、移除列表与二次确认共用一个状态，避免多个浮层同时展开。
struct PlatformManagementState {
    enum Mode: Equatable {
        case adding
        case removing
        case confirmingRemoval(UsagePlatform)
    }

    private(set) var mode: Mode?

    mutating func toggle(_ next: Mode) {
        mode = mode == next ? nil : next
    }
    mutating func dismiss() { mode = nil }
    func candidates(in accounts: PlatformAccounts) -> [UsagePlatform] {
        switch mode {
        case .adding: UsagePlatform.allCases
        case .removing: accounts.ordered
        default: []
        }
    }
    mutating func select(_ platform: UsagePlatform, in accounts: PlatformAccounts) -> UsagePlatform? {
        guard candidates(in: accounts).contains(platform) else { return nil }
        if mode == .adding {
            dismiss()
            return platform
        }
        mode = .confirmingRemoval(platform)
        return nil
    }
    mutating func confirmRemoval(in accounts: PlatformAccounts) -> UsagePlatform? {
        guard case .confirmingRemoval(let platform) = mode else { return nil }
        dismiss()
        return accounts.enabled.contains(platform) ? platform : nil
    }
}
