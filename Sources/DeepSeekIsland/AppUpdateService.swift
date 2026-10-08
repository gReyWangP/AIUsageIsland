import AppKit
import Combine
import Sparkle

@MainActor
protocol AppUpdateBackend: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var onChange: (() -> Void)? { get set }
    func checkForUpdates()
}

@MainActor
final class AppUpdateService: ObservableObject {
    @Published private(set) var canCheckForUpdates: Bool
    @Published private(set) var automaticallyChecksForUpdates: Bool
    private let backend: any AppUpdateBackend
    private let beforePresentation: () -> Void

    init(backend: any AppUpdateBackend, beforePresentation: @escaping () -> Void = {}) {
        self.backend = backend
        self.beforePresentation = beforePresentation
        canCheckForUpdates = backend.canCheckForUpdates
        automaticallyChecksForUpdates = backend.automaticallyChecksForUpdates
        backend.onChange = { [weak self] in self?.refresh() }
    }

    func setAutomaticChecks(_ enabled: Bool) {
        backend.automaticallyChecksForUpdates = enabled
        refresh()
    }

    func checkForUpdates() {
        guard canCheckForUpdates, backend.canCheckForUpdates else { return }
        canCheckForUpdates = false
        beforePresentation()
        backend.checkForUpdates()
        refresh()
    }

    private func refresh() {
        canCheckForUpdates = backend.canCheckForUpdates
        automaticallyChecksForUpdates = backend.automaticallyChecksForUpdates
    }

    static func production(beforePresentation: @escaping () -> Void) -> AppUpdateService? {
        // SwiftPM executables and test runners have no installed update host.
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.bundleIdentifier == "com.deepseekisland.app",
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return nil }
        let backend = SparkleUpdateBackend(beforePresentation: beforePresentation)
        let service = AppUpdateService(backend: backend, beforePresentation: beforePresentation)
        backend.start()
        service.refresh()
        return service
    }
}

@MainActor
private final class SparkleUpdateBackend: NSObject, AppUpdateBackend, @preconcurrency SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController!
    private var observations = Set<AnyCancellable>()
    private let beforePresentation: () -> Void
    var onChange: (() -> Void)?
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    init(beforePresentation: @escaping () -> Void) {
        self.beforePresentation = beforePresentation
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        controller.updater.publisher(for: \.canCheckForUpdates).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }.store(in: &observations)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }.store(in: &observations)
    }
    func start() { controller.startUpdater() }
    func checkForUpdates() { controller.checkForUpdates(nil) }
    func standardUserDriverWillShowModalAlert() { beforePresentation() }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate { beforePresentation() }
    }
}
