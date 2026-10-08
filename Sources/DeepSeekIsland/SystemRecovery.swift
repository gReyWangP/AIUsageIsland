import AppKit
import Network

@MainActor
final class SystemRecoveryController {
    private let model: IslandModel
    private let onSleep: () -> Void
    private let onWake: () -> Void
    private let monitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []
    init(model: IslandModel, onSleep: @escaping () -> Void, onWake: @escaping () -> Void) {
        self.model = model; self.onSleep = onSleep; self.onWake = onWake
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let restored = connected && !self.model.networkAvailable
                self.model.networkAvailable = connected
                if restored && !self.model.isSleeping { await self.model.recoverDataIfNeeded() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "AIUsageIsland.network"))
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.isSleeping = true; self.onSleep()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.isSleeping = false; self.onWake()
                Task { await self.model.recoverDataIfNeeded() }
            }
        })
    }
    func stop() {
        monitor.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }
}

extension IslandPresentation {
    func updateVisibilityForScreenChange(hide: Bool, sleeping: Bool) {
        if sleeping { mode = .hidden }
        else if pinned && mode == .hidden { mode = .expanded }
        else if hide && !pinned { mode = .hidden }
    }

    func applyScreenLayout(_ layout: NotchLayout, screenSize: CGSize,
                           compactLayout: CompactLayout, detailLayout: DetailLayout, platformCount: Int) {
        hasNotch = layout.hasNotch
        notchWidth = layout.notchWidth
        wingWidth = layout.wingWidth
        bandHeight = layout.bandHeight
        topInset = layout.topInset
        horizontalBarWidth = layout.horizontalBarWidth
        screenWidth = screenSize.width
        screenHeight = screenSize.height
        compactSize = compactSize(for: compactLayout)
        detailSize = detailSize(for: detailLayout, platformCount: platformCount)
    }
}
