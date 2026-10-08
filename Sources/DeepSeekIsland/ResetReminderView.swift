import AppKit
import Combine
import SwiftUI

struct ResetReminderView: View {
    let event: OfficialResetAnnouncement
    @ObservedObject var settings: IslandSettings
    @ObservedObject var controller: ResetReminderController
    let onFinish: () -> Void
    @State private var selectedDate: Date?
    @State private var lead: ResetReminderLead
    @State private var destination: ResetReminderDestination
    @State private var validationError: String?
    init(event: OfficialResetAnnouncement, settings: IslandSettings, controller: ResetReminderController, onFinish: @escaping () -> Void) {
        self.event = event; self.settings = settings; self.controller = controller; self.onFinish = onFinish
        let previous = controller.record?.plan
        let selected = previous.flatMap { event.reminderDates.contains($0.selectedDate) ? $0.selectedDate : nil }
        _selectedDate = State(initialValue: selected ?? (event.reminderDates.count == 1 ? event.reminderDates.first : nil))
        _lead = State(initialValue: previous?.lead ?? .atTime)
        _destination = State(initialValue: previous?.destination ?? .notification)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("到时提醒我", systemImage: "bell.badge").font(.system(size: 22, weight: .semibold))
            Text("按北京时间预约检查额度；到点提醒不代表你的额度已经恢复。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text(event.timeDescription).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            if event.reminderDates.count > 1 {
                Text("原帖时区有歧义，请明确选择一个时刻。").font(.system(size: 11)).foregroundStyle(.orange)
            }
            Picker("提醒依据", selection: $selectedDate) {
                Text("请选择北京时间").tag(Optional<Date>.none)
                ForEach(event.reminderDates, id: \.self) { date in
                    Text(OfficialResetAnnouncement.beijingDate(date)).tag(Optional(date))
                }
            }
            Picker("提醒时机", selection: $lead) {
                ForEach(ResetReminderLead.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Picker("保存到", selection: $destination) {
                ForEach(ResetReminderDestination.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Text(destination == .notification
                 ? "由 macOS 发送一次预约通知，无需添加待办。"
                 : "创建一个系统待办，可完成、改期；首次创建需允许访问提醒事项。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("这次主动预约按选定时间提醒，不受应用的提醒时段或“今天暂不提醒”影响。系统专注模式仍可能静默通知。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if controller.record != nil {
                Text("确认后更新已有预约，不会再创建第二个。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let error = validationError ?? controller.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                Button("取消", action: onFinish).keyboardShortcut(.cancelAction)
                Spacer()
                Button(controller.busy ? "正在保存…" : (controller.record == nil ? "确认创建" : "确认更新")) {
                    validationError = nil
                    do {
                        let plan = try ResetReminderPlan.make(event: event, selectedDate: selectedDate, lead: lead, destination: destination)
                        Task {
                            await controller.save(plan)
                            if controller.error == nil && controller.record?.plan == plan { onFinish() }
                        }
                    } catch { validationError = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
                .disabled(selectedDate == nil || event.phase != .scheduled)
            }
        }
        .padding(24).frame(width: 450, height: 510)
        .disabled(controller.busy)
        .background(IslandSettingsBackground(settings: settings))
        .preferredColorScheme(settings.appearanceMode.colorScheme)
    }
}

@MainActor
final class ResetReminderWindowController {
    private let settings: IslandSettings
    private let controller: ResetReminderController
    private var window: NSWindow?
    private var appearance: AnyCancellable?
    init(settings: IslandSettings, controller: ResetReminderController) {
        self.settings = settings; self.controller = controller
        appearance = settings.$appearanceMode.sink { [weak self] mode in self?.window?.appearance = mode.nsAppearance }
    }
    func show(_ event: OfficialResetAnnouncement) {
        let view = ResetReminderView(event: event, settings: settings, controller: controller) { [weak self] in self?.window?.close() }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 510), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "AIUsageIsland · 重置预约"
            w.isReleasedWhenClosed = false
            w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window = w
        }
        guard let window else { return }
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(NSSize(width: 450, height: 510))
        window.appearance = settings.appearanceMode.nsAppearance
        window.backgroundColor = .windowBackgroundColor
        if let screen = ScreenTarget.screen(for: settings.screenSelection, in: NSScreen.screens) {
            let frame = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
        }
        window.makeKeyAndOrderFront(nil); window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

struct ResetReminderStatusView: View {
    @ObservedObject var controller: ResetReminderController
    let latest: OfficialResetAnnouncement?
    var body: some View {
        if let record = controller.record {
            VStack(alignment: .leading, spacing: 6) {
                Text("已预约 · " + record.plan.destination.title).font(.system(size: 10, weight: .semibold))
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(record.plan.remainingDescription(at: context.date)).font(.system(size: 10)).monospacedDigit()
                }
                Text("提醒于 " + OfficialResetAnnouncement.beijingDate(record.plan.notifyAt)).font(.system(size: 9)).foregroundStyle(.secondary)
                if let latest, controller.needsUpdate(for: latest) {
                    Text(latest.id == record.plan.event.id ? "预告时间已变更，请确认是否更新预约。" : "发现新的重置预告，可更新已有预约。")
                        .font(.system(size: 9)).foregroundStyle(.orange)
                    Button("更新预约") { controller.present(latest) }.buttonStyle(.link)
                }
                HStack {
                    Button("调整预约") { controller.present(record.plan.event) }.buttonStyle(.link)
                    Spacer()
                    Button(controller.busy ? "处理中…" : "取消预约") { Task { await controller.cancel() } }
                        .disabled(controller.busy)
                }.font(.system(size: 9))
                if let error = controller.error { Text(error).font(.system(size: 9)).foregroundStyle(.orange) }
            }
            .padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
