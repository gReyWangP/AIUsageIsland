import AppKit
import Combine
import SwiftUI

/// 独立设置窗口中的屏幕与排版偏好；修改排版时同步预览对应岛形。
struct IslandSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    private var palette: IslandPalette { IslandPalette(scheme: settings.appearanceMode.colorScheme ?? colorScheme) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var settings: IslandSettings
    @ObservedObject var model: IslandModel
    var utilities: DailyUtilities? = nil
    var updater: AppUpdateService? = nil
    @State private var selectedPage = 1
    var onShowGuide: () -> Void = {}
    var onPreview: (IslandPresentation.Mode) -> Void = { _ in }
    var initiallySelectedPage = 1

    init(settings: IslandSettings, model: IslandModel, utilities: DailyUtilities? = nil, updater: AppUpdateService? = nil,
         onShowGuide: @escaping () -> Void = {}, onPreview: @escaping (IslandPresentation.Mode) -> Void = { _ in },
         initiallySelectedPage: Int = 1) {
        self.settings = settings; self.model = model; self.utilities = utilities; self.updater = updater
        self.onShowGuide = onShowGuide; self.onPreview = onPreview
        self.initiallySelectedPage = initiallySelectedPage
        _selectedPage = State(initialValue: initiallySelectedPage)
    }

    @State private var screens: [NSScreen] = NSScreen.screens

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            brandHeader
            HStack(alignment: .top, spacing: 16) {
                sidebar
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    if selectedPage == 1 {
                        AccountSettingsView(model: model, settings: settings)
                    } else if selectedPage == 2 {
                        if let utilities {
                            UtilitySettingsView(model: model, settings: settings, login: utilities.login, alerts: utilities.alerts, shortcuts: utilities.shortcuts, updater: updater)
                        } else {
                            Text("启动应用后可调整通用设置。")
                        }
                    } else if selectedPage == 3 {
                        if let utilities {
                            ReminderPreferencesView(model: model, settings: settings, alerts: utilities.alerts)
                        } else {
                            Text("启动应用后可调整提醒设置。")
                        }
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                appearanceSection.settingsCard()
                                screenSection.settingsCard()
                                DisclosureGroup("高级外观") {
                                    VStack(alignment: .leading, spacing: 16) {
                                        menuBarSection
                                        layoutSection
                                        FloatingContentSettings(settings: settings, model: model)
                                    }.padding(.top, 8)
                                }.settingsCard()
                            }.padding(.trailing, 5)
                        }
                    }
                    HStack {
                        Text("在屏幕顶部查看实际尺寸").font(.footnote).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button("预览悬浮") { onPreview(.compact) }
                        Button("预览明细") { onPreview(.expanded) }
                    }.font(.callout)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { selectedPage = initiallySelectedPage }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
            settings.reconcileScreenSelection(in: screens)
        }
        .preferredColorScheme(settings.appearanceMode.colorScheme)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("设置").font(.system(size:10,weight:.semibold)).foregroundStyle(.secondary).padding(.horizontal,10).padding(.bottom,4)
            sidebarButton("账号", icon:"person.crop.rectangle", page:1)
            sidebarButton("外观", icon:"rectangle.3.group", page:0)
            sidebarButton("提醒", icon:"bell", page:3)
            sidebarButton("通用与支持", icon:"gearshape", page:2)
            Divider().padding(.vertical,6)
            Button {
                if let account=model.visibleAccounts.first ?? model.orderedSavedAccounts.first {
                    UsageAnalysisWindowController.shared.show(model:model,account:account)
                }
            } label: {
                HStack(spacing:8) {
                    Image(systemName:"chart.bar.xaxis").frame(width:14)
                    Text("用量分析")
                    Spacer(minLength:0)
                    Image(systemName:"arrow.up.right").font(.footnote).foregroundStyle(.secondary)
                }.padding(.horizontal,10).padding(.vertical,9).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(model.savedAccounts.isEmpty).help("打开独立用量分析窗口")
            Spacer(minLength:0)
        }.font(.callout).frame(width:140,alignment:.leading)
    }
    private func sidebarButton(_ title:String, icon:String, page:Int) -> some View {
        Button { selectedPage=page } label: {
            HStack(spacing:8) {
                Image(systemName:icon).frame(width:14)
                Text(title)
                Spacer(minLength:0)
            }.padding(.horizontal,10).padding(.vertical,9)
                .background(selectedPage == page ? Color.accentColor.opacity(0.16) : .clear,in:RoundedRectangle(cornerRadius:8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityAddTraits(selectedPage == page ? [.isSelected] : [])
    }

    private func menuCapability(_ metric: UsageMetric) -> MetricCapability {
        let account = settings.menuBarAccount ?? model.menuBarAccount(for: metric.platform)
        return model.accountRuntime(for: account).capabilities.metric(metric)
    }

    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle("状态栏")
            Text("开关与显示账号在“账号与显示”中设置。")
                .font(.footnote).foregroundStyle(.secondary)
            if settings.showsMenuBarItem {
            Text(settings.menuBarAccount.map(model.accountLabel) ?? model.activeAccountLabel(for: settings.menuBarMetric.platform))
                .font(.callout).foregroundStyle(palette.foreground.opacity(0.85))
            Toggle("自动关注", isOn: $settings.menuBarAutoFocusEnabled).toggleStyle(SettingsToggleStyle())
                .font(.callout).help("仅比较所选账号的额度窗口。")
            Picker(settings.menuBarAutoFocusEnabled ? "基准窗口" : "额度窗口", selection: $settings.menuBarMetric) {
                ForEach(UsageMetric.allCases.filter { $0.platform == settings.menuBarMetric.platform }) { metric in
                    Text((metric == .deepSeekBalance ? "剩余余额" : metric.windowLabel + "剩余额度") + menuCapability(metric).suffix).tag(metric)
                        .disabled(!menuCapability(metric).canSelect)
                }
            }
            .font(.callout)
            Text("顶部只显示一个图标；自动关注仅比较所选账号的额度窗口。")
                .font(.footnote).foregroundStyle(palette.foreground.opacity(0.65))
            Picker("进度样式", selection: $settings.menuBarProgressStyle) {
                ForEach(MenuBarProgressStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .font(.callout)
            .disabled(!settings.showsMenuBarItem || (settings.menuBarMetric == .deepSeekBalance && !settings.menuBarAutoFocusEnabled))
            .help("水位表示剩余额度，从底部水平填充，不播放动画。")
            if settings.menuBarProgressStyle == .ring {
                Picker("圆环粗细", selection: $settings.menuBarRingThickness) {
                    ForEach(MenuBarRingThickness.allCases) { thickness in
                        Text(thickness.title).tag(thickness)
                    }
                }
                .pickerStyle(.segmented)
                .font(.callout)
                .disabled(!settings.showsMenuBarItem || (settings.menuBarMetric == .deepSeekBalance && !settings.menuBarAutoFocusEnabled))
                .help("仅用于套餐剩余额度的圆环，余额图标不受影响。")
            }
            Text("绿健康 · 黄偏低 · 红严重；右键切换或刷新，自动时显示窗口。")
                .font(.footnote)
                .foregroundStyle(palette.foreground.opacity(0.65))
            }
        }
        .onChange(of: settings.showsMenuBarItem) { _, enabled in
            if enabled, !model.platformAccounts.enabled.contains(settings.menuBarPlatform),
               let first = model.platformAccounts.ordered.first { settings.menuBarPlatform = first }
        }
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("外观")
            segmented(AppearanceMode.allCases, selection: settings.appearanceMode) {
                settings.appearanceMode = $0
            }
            sectionTitle("背景效果")
            segmented(BackgroundEffect.allCases, selection: settings.backgroundEffect) {
                settings.backgroundEffect = $0
            }
            Text("毛玻璃会模糊透出背后的窗口；系统减少透明度时使用纯色。")
                .font(.footnote)
                .foregroundStyle(palette.foreground.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 标识

    /// 设置窗口顶部的 logo 与版本号。
    ///
    /// 这段会改变窗口内容高度：`AppDelegate.settingsWindowHeight` 必须跟着更新，
    /// 否则窗口底部会截掉最后一项设置（数值由 `DetailLayoutTests` 实测）。
    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IslandLogoMark(size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(IslandBrand.name)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.foreground.opacity(0.95))
                    Text("版本 \(IslandBrand.version) · 显示 \(model.visibleAccounts.count) 个账号 · 状态栏\(settings.showsMenuBarItem ? "开启" : "关闭")")
                        .font(.footnote)
                        .foregroundStyle(palette.foreground.opacity(0.65))
                }
                Spacer(minLength: 0)
                Button(action: onShowGuide) {
                    Label("使用引导", systemImage: "questionmark.circle")
                        .font(.footnote)
                        .frame(minHeight: 24).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(palette.accent)
            }
            Rectangle()
                .fill(palette.foreground.opacity(0.08))
                .frame(height: 1)
        }
    }

    // MARK: - 显示屏幕

    private var screenSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle("显示屏幕")
            let single = screens.count <= 1
            VStack(alignment: .leading, spacing: 4) {
                choiceRow(title: "自动",
                          subtitle: "移到哪块屏幕顶部，就在哪块屏幕弹出",
                          selected: settings.screenSelection == .automatic,
                          enabled: !single) {
                    settings.screenSelection = .automatic
                }
                ForEach(screens, id: \.self) { screen in
                    let id = Self.displayID(of: screen)
                    choiceRow(title: Self.name(of: screen),
                              subtitle: Self.describe(screen),
                              selected: settings.screenSelection.displayID == id,
                              enabled: !single) {
                        settings.screenSelection = .display(id: id, name: screen.localizedName)
                    }
                }
            }
            .opacity(single ? 0.45 : 1)
            if single {
                Text("当前只连接了一块屏幕，这项设置暂不生效。接入第二块屏幕后即可选择。")
                    .font(.footnote)
                    .foregroundStyle(palette.foreground.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .display(let id, let name) = settings.screenSelection,
               !screens.contains(where: { Self.displayID(of: $0) == id }),
               !screens.contains(where: { $0.localizedName == name }) {
                Text("已选屏幕“\(name)”当前未连接，暂时显示在可用屏幕上；重新接入后会回到该屏幕。")
                    .font(.footnote)
                    .foregroundStyle(palette.foreground.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 排版

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                sectionTitle("显示形式")
                Picker("显示形式", selection: $settings.displayMode) {
                    Text("顶部灵动岛").tag(IslandDisplayMode.island)
                    Text("悬浮状态栏").tag(IslandDisplayMode.floating)
                    Text("侧边停靠").tag(IslandDisplayMode.sideDock)
                }.pickerStyle(.segmented).labelsHidden()
                if settings.displayMode == .sideDock {
                    Picker("停靠位置", selection: $settings.sideDockOnLeft) {
                        Text("屏幕左侧").tag(true)
                        Text("屏幕右侧").tag(false)
                    }
                    Picker("展开方式", selection: $settings.sideDockAutoHide) {
                        Text("移入展开").tag(true)
                        Text("固定贴边").tag(false)
                    }.pickerStyle(.segmented)
                    HStack(spacing: 10) {
                        Text("侧栏圆弧")
                        Slider(value: $settings.sideDockCurveDepth,
                               in: Double(SideDockLayout.minCurveDepth)...Double(SideDockLayout.maxCurveDepth),
                               step: 1)
                            .tint(palette.accent)
                        Text("\(Int(settings.sideDockCurveDepth))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 22, alignment: .trailing)
                    }
                    Text("侧栏可直接上下拖动调整位置；圆弧从直角内角开始圆化，继续增大后再过渡为 S 形贴边。")
                        .font(.footnote).foregroundStyle(palette.foreground.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(settings.sideDockAutoHide
                         ? "鼠标离开后自动收起为边缘细条，移入时动画展开；查看详情期间保持展开。"
                         : "黑色侧栏与屏幕边缘相连，常驻显示平台用量；悬停预览详情，点击固定详情。")
                        .font(.footnote).foregroundStyle(palette.foreground.opacity(0.65))
                }
                if settings.displayMode == .floating {
                    Toggle("状态栏常驻展开", isOn: $settings.floatingStatusAlwaysExpanded)
                    Text("开启后保持展开，不自动缩进边缘；仍可自由拖动、吸附和悬停查看平台详情。")
                        .font(.footnote).foregroundStyle(palette.foreground.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("悬浮状态栏模式同时显示已启用平台；拖动靠近顶部或左右边缘吸附。移出后贴边收起，移入展开，悬停图标预览、点击固定详情。DeepSeek 圆环按余额变色：≥5 为绿色，1–5 为黄色，<1 为红色（账户币种）。")
                    .font(.footnote).foregroundStyle(palette.foreground.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 7) {
                sectionTitle("悬浮内容排版")
                segmented(CompactLayout.allCases, selection: settings.compactLayout) {
                    settings.compactLayout = $0
                }
                Text(settings.compactLayout.detail)
                    .font(.footnote)
                    .foregroundStyle(palette.foreground.opacity(0.65))
            }
            VStack(alignment: .leading, spacing: 7) {
                sectionTitle("详情排版")
                segmented(DetailLayout.allCases, selection: settings.detailLayout) {
                    settings.detailLayout = $0
                }
                Text(settings.detailLayout.detail)
                    .font(.footnote)
                    .foregroundStyle(palette.foreground.opacity(0.65))
            }
        }
    }

    // MARK: - 组件

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(palette.foreground.opacity(0.72))
    }

    private func choiceRow(title: String,
                           subtitle: String,
                           selected: Bool,
                           enabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.callout)
                    .foregroundStyle(selected ? palette.accent : palette.foreground.opacity(0.35))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(palette.foreground.opacity(selected ? 0.95 : 0.75))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(palette.foreground.opacity(0.38))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(selected ? palette.accent.opacity(0.10) : palette.foreground.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(enabled ? "" : "当前只有一块屏幕")
    }

    private func segmented<T: Identifiable & Equatable>(_ items: [T],
                                                        selection: T,
                                                        onPick: @escaping (T) -> Void) -> some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                let selected = item == selection
                Button {
                    withAnimation(reduceMotion ? nil : IslandMotion.surface) {
                        onPick(item)
                    }
                } label: {
                    Text(label(for: item))
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? palette.foreground : palette.foreground.opacity(0.62))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(selected ? palette.accent.opacity(0.22) : palette.foreground.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func label<T>(for item: T) -> String {
        switch item {
        case let mode as AppearanceMode: mode.title
        case let effect as BackgroundEffect: effect.title
        case let layout as CompactLayout: layout.title
        case let layout as DetailLayout: layout.title
        default: ""
        }
    }

    // MARK: - 屏幕信息

    static func displayID(of screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? 0
    }

    static func name(of screen: NSScreen) -> String {
        screen.localizedName
    }

    static func describe(_ screen: NSScreen) -> String {
        let id = displayID(of: screen)
        let builtIn = id != 0 && CGDisplayIsBuiltin(id) != 0
        let size = "\(Int(screen.frame.width))×\(Int(screen.frame.height))"
        var parts = [size]
        if builtIn { parts.append("内建") }
        if screen.auxiliaryTopLeftArea != nil { parts.append("带刘海") }
        if screen == NSScreen.main { parts.append("主屏") }
        return parts.joined(separator: " · ")
    }
}
