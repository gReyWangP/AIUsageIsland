import AppKit
import Combine
import ServiceManagement

enum LoginLaunchStatus { case enabled, notRegistered, requiresApproval, notFound }
@MainActor
protocol LoginLaunchBackend {
    var status: LoginLaunchStatus { get }
    func setEnabled(_ enabled: Bool) async throws
}
@MainActor
final class SystemLoginLaunchBackend: LoginLaunchBackend {
    var status: LoginLaunchStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }
    func setEnabled(_ enabled: Bool) async throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try await SMAppService.mainApp.unregister() }
    }
}
@MainActor
final class LoginLaunchController: ObservableObject {
    @Published private(set) var status: LoginLaunchStatus
    @Published private(set) var changing = false
    @Published private(set) var error: String?
    private let backend: any LoginLaunchBackend
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var statusText: String {
        switch status {
        case .enabled: "已启用，登录 Mac 时自动启动"
        case .requiresApproval: "等待系统批准，请在登录项设置中允许"
        case .notRegistered: "未启用；建议先将应用放入“应用程序”文件夹"
        case .notFound: "系统暂未识别当前应用，请放入“应用程序”后重试"
        }
    }
    init(backend: any LoginLaunchBackend = SystemLoginLaunchBackend()) {
        self.backend = backend; status = backend.status
    }
    func refreshStatus() { status = backend.status }
    func setEnabled(_ enabled: Bool) async {
        guard !changing else { return }
        changing = true; error = nil
        defer { changing = false; refreshStatus() }
        do { try await backend.setEnabled(enabled) }
        catch { self.error = "无法更改自动启动：\(error.localizedDescription)" }
    }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
