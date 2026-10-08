import AppKit
import Combine
import SwiftUI

struct QuotaReminderView: View {
    let proposal: QuotaReminderPlan
    @ObservedObject var controller: QuotaReminderController
    @ObservedObject var settings: IslandSettings
    let onFinish: () -> Void
    @State private var lead: ResetReminderLead = .atTime
    @State private var validationError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
            Label("个人额度到时提醒", systemImage: "bell.badge").font(.system(size: 21, weight: .semibold))
            Text(proposal.metric.platform.title + " · " + proposal.metric.windowLabel).font(.headline)
            if !proposal.accountLabel.isEmpty { Text("账号：" + proposal.accountLabel).font(.system(size: 12)) }
            Text("预计重置：" + OfficialResetAnnouncement.beijingDate(proposal.resetAt)).font(.system(size: 12))
            Picker("提醒时机", selection: $lead) {
                ForEach(ResetReminderLead.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Text("到点只提醒你检查额度；刷新确认额度增加后，才会发送“额度已恢复”通知。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("由 macOS 预约通知，退出工具后仍可提醒。主动预约不受应用提醒时段和“今天暂不提醒”影响；系统专注模式仍可能静默通知。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let old = controller.plan(for: proposal.metric, accountKey: proposal.accountKey) {
                Text("已有预约：" + OfficialResetAnnouncement.beijingDate(old.notifyAt) + "；确认后替换此窗口的预约。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = validationError ?? controller.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("取消", action: onFinish).keyboardShortcut(.cancelAction)
                Spacer()
                Button(controller.busy ? "正在预约…" : "确认预约") {
                    validationError = nil
                    do {
                        let plan = try QuotaReminderPlan.make(metric: proposal.metric, resetAt: proposal.resetAt, lead: lead, accountKey: proposal.accountKey, accountLabel: proposal.accountLabel)
                        Task { await controller.save(plan); if controller.error == nil { onFinish() } }
                    } catch { validationError = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 450, height: 440).disabled(controller.busy)
        .background(IslandSettingsBackground(settings: settings)).preferredColorScheme(settings.appearanceMode.colorScheme)
        .onAppear { lead = controller.plan(for: proposal.metric, accountKey: proposal.accountKey)?.lead ?? .atTime }
    }
}
@MainActor final class QuotaReminderWindowController {
    private let settings: IslandSettings
    private let controller: QuotaReminderController
    private var window: NSWindow?
    private var appearance: AnyCancellable?
    init(settings: IslandSettings, controller: QuotaReminderController) {
        self.settings = settings; self.controller = controller
        appearance = settings.$appearanceMode.sink { [weak self] mode in self?.window?.appearance = mode.nsAppearance }
    }
    func show(_ plan: QuotaReminderPlan) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 440), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "AIUsageIsland · 个人额度预约"; w.isReleasedWhenClosed = false
            w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; window = w
        }
        guard let window else { return }
        window.contentViewController = NSHostingController(rootView: QuotaReminderView(proposal: plan, controller: controller, settings: settings) { [weak self] in self?.window?.close() })
        window.setContentSize(NSSize(width: 450, height: 440)); window.appearance = settings.appearanceMode.nsAppearance
        if let screen = ScreenTarget.screen(for: settings.screenSelection, in: NSScreen.screens) {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - window.frame.width / 2, y: screen.visibleFrame.midY - window.frame.height / 2))
        }
        window.makeKeyAndOrderFront(nil); window.orderFrontRegardless(); NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
struct QuotaReminderSettingsView: View {
    @ObservedObject var controller: QuotaReminderController
    var body: some View {
        if !controller.accountPlans.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text("个人额度预约").fontWeight(.semibold)
                ForEach(controller.accountPlans.values.sorted { $0.id < $1.id }, id: \.id) { plan in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text((plan.accountLabel.isEmpty ? plan.metric.platform.title : plan.accountLabel) + " · " + plan.metric.windowLabel)
                            Spacer(); Button("取消预约") { controller.cancel(plan) }.buttonStyle(.link)
                        }
                        Text((plan.notifyAt > .now ? "提醒于 " : "预约时间已到 · ") + OfficialResetAnnouncement.beijingDate(plan.notifyAt))
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
struct AlertThresholdSettingsView: View {
    @ObservedObject var settings: IslandSettings
    var initiallyExpanded = false
    @State private var expanded = false
    @State private var metric = UsageMetric.deepSeekBalance
    @State private var warning: Double = 5
    @State private var critical: Double = 1
    @State private var error: String?
    var body: some View {
        DisclosureGroup("自定义通知阈值", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("指标", selection: $metric) { ForEach(UsageMetric.allCases) { Text($0.title).tag($0) } }
                HStack {
                    Text("偏低"); TextField("偏低", value: $warning, format: .number).frame(width: 60)
                    Text("严重"); TextField("严重", value: $critical, format: .number).frame(width: 60)
                    Text(metric == .deepSeekBalance ? "元" : "%")
                }
                HStack {
                    Button("保存阈值") {
                        do { settings.alertThresholds[metric] = try .make(warning: warning, critical: critical, metric: metric); error = nil }
                        catch { self.error = error.localizedDescription }
                    }
                    Button("恢复默认") { settings.alertThresholds.removeValue(forKey: metric); load() }
                }
                Text("仅改变通知判断；图标颜色仍按原标准。低于严重阈值可升级提醒，同周期同等级不重复。")
                    .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error { Text(error).font(.system(size: 9)).foregroundStyle(.orange) }
            }.padding(.top, 6)
        }.disclosureGroupStyle(SettingsDisclosureGroupStyle())
        .onAppear { expanded = initiallyExpanded; load() }.onChange(of: metric) { _, _ in load() }
    }
    private func load() { let value = settings.thresholds(for: metric); warning = value.warning; critical = value.critical; error = nil }
}
