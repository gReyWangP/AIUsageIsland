import SwiftUI

/// 顶部收口的圆角形状：上边平、下边圆。
private struct IslandSurface: Shape {
    var size: CGSize
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(size.width, size.height), bottomRadius) }
        set {
            size = CGSize(width: newValue.first.first, height: newValue.first.second)
            bottomRadius = newValue.second
        }
    }

    func path(in canvas: CGRect) -> Path {
        // 尺寸在路径内补间，锚点永远取当前画布中心。
        // 若动画 .frame(width:) 的位置，画布扩大时旧中心会先落到左侧。
        let rect = CGRect(x: canvas.midX - size.width / 2, y: canvas.minY,
                          width: max(0, size.width), height: max(0, size.height))
        let radius = min(bottomRadius, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct IslandView: View {
    @Environment(\.colorScheme) private var colorScheme
    private var palette: IslandPalette { IslandPalette(scheme: settings.appearanceMode.colorScheme ?? colorScheme) }
    @ObservedObject var officialResetCard: OfficialResetCardState
    @ObservedObject var model: IslandModel
    @ObservedObject var presentation: IslandPresentation
    @ObservedObject var settings: IslandSettings
    /// 添加、移除与二次确认浮层互斥。
    @State private var platformManagement = PlatformManagementState()
    @State private var accountRemoval: AccountReference?
    @State private var confirmsAccountRemoval = false
    @Namespace private var detailMotionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatedSurfaceSize: CGSize = .zero
    @State private var renderedCompactLayout: CompactLayout = .horizontal
    @State private var renderedCompactSize = CGSize(width: 565, height: 55)
    @State private var animatedMode: IslandPresentation.Mode = .hidden

    init(model: IslandModel, presentation: IslandPresentation, settings: IslandSettings) {
        self.officialResetCard = model.officialResetCard
        self.model = model
        self.presentation = presentation
        self.settings = settings
        // 初次挂载从真实设置和当前尺寸开始，不能先显示默认横向再做一次反向动画。
        _animatedSurfaceSize = State(initialValue: presentation.surfaceTransition.size)
        _animatedMode = State(initialValue: presentation.surfaceTransition.mode)
        _renderedCompactLayout = State(initialValue: settings.compactLayout)
        _renderedCompactSize = State(initialValue: presentation.compactSize)
    }

    /// 实测尺寸的合法上限。越界一律视为测量失败丢弃——
    /// 一个失控的尺寸会让面板变成盖住整块屏幕的黑窗口。
    private static let maxMeasuredSide: CGFloat = 4096
    /// 尺寸异常时的兜底面板高度，保证悬浮条仍然可见可点。
    static let fallbackPanelHeight: CGFloat = 55
    // MARK: - 尺寸

    private var compactSize: CGSize { presentation.compactSize }

    /// 悬浮条当前应有的宽度。纵向排版下取刘海宽度（不低于 170），
    /// 外接屏取 200——与 `IslandCompactBar.verticalWidth` 保持一致。
    private var compactBarWidth: CGFloat {
        presentation.compactSize(for: settings.compactLayout).width
    }

    private var detailPanelWidth: CGFloat {
        switch settings.detailLayout {
        case .columns:
            return DetailMetrics.panelWidth(
                platformCount: model.detailSnapshots.count,
                screenWidth: presentation.screenWidth
            )
        case .stacked:
            return NotchLayout.externalBarWidth
        }
    }

    /// 面板宽度兜底：屏幕尺寸还没测到时先用固定值，别算出 0 或负数。
    private var safeDetailPanelWidth: CGFloat {
        let width = detailPanelWidth
        guard width.isFinite, width > 1 else { return NotchLayout.externalBarWidth }
        return width
    }

    private var detailPanelHeight: CGFloat { presentation.detailSize.height }
    private var detailSize: CGSize { presentation.detailSize }

    private var surfaceSize: CGSize {
        let raw: CGSize
        switch presentation.mode {
        case .hidden:
            raw = CGSize(width: presentation.hasNotch ? presentation.notchWidth : 0,
                         height: presentation.hasNotch ? presentation.bandHeight : 0)
        case .compact:
            raw = compactSize
        case .expanded:
            raw = detailSize
        }
        // 最后一道钳制：黑色底板永远不得超出容器，
        // 否则它会变成盖住整块屏幕的黑窗口。
        let limit = maxSize
        return CGSize(width: min(max(raw.width, 0), limit.width),
                      height: min(max(raw.height, 0), limit.height))
    }

    private var maxSize: CGSize {
        CGSize(width: max(compactSize.width, detailSize.width),
               height: max(compactSize.height, detailSize.height))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                IslandBackground(effect: settings.backgroundEffect)
                    .clipShape(IslandSurface(size: animatedSurfaceSize,
                                             bottomRadius: animatedMode == .expanded ? 14 : 9))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .shadow(color: .black.opacity(animatedMode == .expanded ? 0.35 : 0),
                            radius: animatedMode == .expanded ? 18 : 0, y: 8)
                    .animation(surfaceAnimation, value: animatedSurfaceSize)

                compactBar(canvasWidth: geometry.size.width)
                    .animation(reduceMotion ? nil : IslandMotion.surface, value: renderedCompactSize)
                    .animation(reduceMotion ? nil : IslandMotion.surface, value: renderedCompactLayout)
                    .opacity(animatedMode == .compact ? 1 : 0)
                    .allowsHitTesting(presentation.mode == .compact)
                    .animation(IslandMotion.content, value: animatedMode)

                detailContent
                    .modifier(IslandCenteredFrame(
                        size: CGSize(width: safeDetailPanelWidth, height: detailPanelHeight),
                        canvasWidth: geometry.size.width))
                    .animation(reduceMotion ? nil : IslandMotion.surface, value: settings.detailLayout)
                    .animation(reduceMotion ? nil : IslandMotion.surface, value: presentation.detailSize)
                    .opacity(animatedMode == .expanded ? 1 : 0)
                    .offset(y: reduceMotion || animatedMode == .expanded ? 0 : -6)
                    .allowsHitTesting(presentation.expanded)
                    .animation(IslandMotion.content, value: animatedMode)
            }
            // 用动画期间的窗口包络作画布，不让目标布局提前缩小裁切区。
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .mask(alignment: .top) {
                IslandSurface(size: animatedSurfaceSize, bottomRadius: animatedMode == .expanded ? 14 : 9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(surfaceAnimation, value: animatedSurfaceSize)
            }
            // AppKit 的包络变化应立刻更新坐标系，不能插值旧画布的中心。
            // 子视图各自显式动画，仍保留尺寸、位置和透明度的连续过渡。
            .animation(nil, value: geometry.size)
        }
        .onAppear { publishDetailSize(); animateSurface(presentation.surfaceTransition) }
        .onChange(of: presentation.surfaceTransition) { _, target in animateSurface(target) }
        .onChange(of: settings.compactLayout) { _, _ in animateCompactContent() }
        .onChange(of: presentation.compactSize) { _, _ in animateCompactContent() }
        .preferredColorScheme(settings.appearanceMode.colorScheme)
        .ignoresSafeArea()
        .onChange(of: presentation.mode) { _, newMode in
            if newMode == .expanded { publishDetailSize() }
            // 只在收起时复位。若写成「任何 mode 变化都复位」，
            // 展开动作本身就会把刚打开的列表关掉。
            if newMode != .expanded { platformManagement.dismiss(); model.notificationDetailAccount = nil }
            logRenderState(reason: "mode->\(newMode)")
        }
        // 排版变了：宽度是策略推导的，高度取该排版自己的缓存值，
        // 两者必须同属一个排版，否则会发出混合尺寸。
        .onChange(of: settings.detailLayout) { _, _ in publishDetailSize() }
        .onChange(of: model.platformAccounts.enabled) { _, _ in publishDetailSize() }
        .onChange(of: model.visibleAccounts) { _, _ in publishDetailSize() }
        .onChange(of: model.notificationDetailAccount) { _, _ in publishDetailSize() }
        .onChange(of: presentation.compactSize) { _, _ in logRenderState(reason: "compactSize") }
        .onChange(of: presentation.detailSize) { _, _ in logRenderState(reason: "detailSize") }
        .onChange(of: presentation.showingSettings) { _, _ in logRenderState(reason: "settings") }
        .confirmationDialog("移除 \(accountRemoval.map(model.accountLabel) ?? "这个账号")？", isPresented: $confirmsAccountRemoval, titleVisibility: .visible) {
            Button("移除「\(accountRemoval.map(model.accountLabel) ?? "这个账号")」", role: .destructive) {
                if let accountRemoval { Task { await model.removeAccount(accountRemoval) } }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("仅清除这个账号的本机授权和用量记录，其他账号保留。") }
    }

    private var surfaceAnimation: Animation? {
        presentation.surfaceTransition.animated && !reduceMotion ? IslandMotion.surface : nil
    }

    private func animateSurface(_ target: IslandSurfaceTransition) {
        withAnimation(target.animated && !reduceMotion ? IslandMotion.surface : nil,
                      completionCriteria: .removed) {
            animatedSurfaceSize = target.size
            animatedMode = target.mode
            renderedCompactLayout = settings.compactLayout
            renderedCompactSize = compactSize
        } completion: {
            presentation.onSurfaceSettled?(target.revision)
        }
    }

    private func animateCompactContent() {
        withAnimation(reduceMotion ? nil : IslandMotion.surface) {
            renderedCompactLayout = settings.compactLayout
            renderedCompactSize = compactSize
        }
    }

    // MARK: - 悬浮条

    private func compactBar(canvasWidth: CGFloat) -> some View {
        IslandCompactMorph(
            snapshots: model.snapshots,
            layout: renderedCompactLayout,
            hasNotch: presentation.hasNotch,
            horizontalWidth: presentation.horizontalBarWidth,
            notchWidth: presentation.notchWidth,
            bandHeight: presentation.bandHeight,
            size: renderedCompactSize,
            canvasWidth: canvasWidth,
            horizontalProgress: renderedCompactLayout == .horizontal ? 1 : 0,
            onContentSizeChange: { layout, size in receiveCompactSize(size, layout: layout) },
            onTap: { presentation.expanded.toggle() }
        )
    }

    // MARK: - 详情

    private var detailContent: some View {
        VStack(spacing: 10) {
            detailHeader

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        detailBody
                            // 每个排版按自己的最终宽度测量，外框补间不参与文字换行。
                            .frame(width: max(1, safeDetailPanelWidth - 2 * DetailMetrics.horizontalPadding))
                    }
                    // 固定宽度的卡片在当前视口内居中，不能再跟着插值中的左边缘走。
                    .frame(maxWidth: .infinity, alignment: .center)
                    // 标题和主要数字通过共享几何移动，其余内容短交叉渐变。
                    .id(settings.detailLayout)
                    .transition(.opacity)
                    .animation(reduceMotion ? nil : IslandMotion.surface,
                               value: settings.detailLayout)
                }
                // macOS 的常驻滚动条不能在溢出状态变化时挤占、释放卡片宽度。
                .scrollIndicators(.never)
                .task(id: model.detailFocus?.id) {
                    await Task.yield()
                    if let focus = model.detailFocus {
                        let target = "\(focus.accountID ?? model.activeAccountReference(for: focus.platform).id)-\(focus.rowID)"
                        proxy.scrollTo(target, anchor: .center)
                        // 展开动画和实测尺寸完成后再定位一次，避免用收起态视口计算位置。
                        try? await Task.sleep(for: .milliseconds(450))
                        guard !Task.isCancelled, model.detailFocus?.id == focus.id,
                              presentation.expanded else { return }
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }

            HStack {
                removePlatformControl
                addPlatformControl
                Spacer()
                Button { NSApplication.shared.terminate(nil) } label: {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.foreground.opacity(0.70))
                        .frame(width: 26, height: 26)
                        .background(palette.foreground.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .help("退出应用")
                .accessibilityLabel("退出应用")
            }
            .overlay(alignment: .bottomLeading) {
                if platformManagement.mode != nil {
                    platformManagementPopup.offset(y: -34)
                }
            }
        }
        .padding(.horizontal, DetailMetrics.horizontalPadding)
        .padding(.top, presentation.topInset)
        .padding(.bottom, 13)
    }

    private var detailHeader: some View {
        HStack(spacing: 8) {
            IslandLogoMark(size: 16)
            Text(detailTitle)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .fixedSize(horizontal: true, vertical: false)
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.mini)
                    .help("正在刷新平台用量；悬停不会触发刷新")
            }
            Button { presentation.onToggleSettings?() } label: {
                Image(systemName: presentation.showingSettings ? "gearshape.fill" : "gearshape")
                    .foregroundStyle(presentation.showingSettings
                                     ? palette.accent : palette.foreground.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help(presentation.showingSettings ? "返回用量" : "设置")
            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.isRefreshing
                      || !(model.accountConnected || model.zhipuConnected || model.chatGPTConnected))
            .help("刷新")
            IslandPinButton(pinned: $presentation.pinned)
            Button { presentation.expanded = false; presentation.pinned = false } label: {
                Image(systemName: "chevron.up")
            }
            .help("收起详情")
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.foreground)
        .font(.system(size: 12))
    }

    @ViewBuilder private var detailBody: some View {
        if model.detailSnapshots.isEmpty {
            VStack(spacing: 12) {
                if model.savedAccounts.isEmpty {
                    PlatformPickerView { platform in Task { await model.addAccount(platform: platform, label: "") } }
                } else {
                    Text("尚未选择显示的账号").font(.system(size: 12))
                    Button("选择显示账号") { presentation.onToggleSettings?() }
                }
            }
        } else {
            switch settings.detailLayout {
            case .columns:
                IslandDetailColumns(
                    snapshots: model.detailSnapshots,
                    motionNamespace: reduceMotion ? nil : detailMotionNamespace,
                    focus: model.detailFocus,
                    officialReset: OfficialResetCardContent.make(officialResetCard.announcement, enabled: settings.officialResetAlertsEnabled),
                    officialResetLastChecked: officialResetCard.lastChecked,
                    officialResetError: officialResetCard.error,
                    onReserveOfficialReset: { officialResetCard.onReserve?($0) },
                    onOfficialPopoverChange: { officialResetCard.isPopoverPresented = $0 },
                    onContentHeightChange: { layout, size in receiveMeasuredHeight(size, layout: layout) },
                    onDisconnect: { requestPlatformRemoval($0) },
                    onSignIn: { platform in Task { await model.signIn(platform) } },
                    onReserveQuotaReset: { platform, row in model.reserveQuotaReset(platform: platform, row: row) },
                    onRefresh: { platform in
                        Task {
                            await model.refresh(platform)
                        }
                    },
                    onAccountDisconnect: { requestAccountRemoval($0) },
                    onAccountSignIn: { id in Task { await model.signInAccount(id: id) } },
                    onAccountRefresh: { id in Task { await model.refreshAccount(id: id) } },
                    onAccountReserveQuotaReset: { id, row in Task { await model.reserveQuotaReset(accountID: id, row: row) } },
                    onAccountAnalysis: { id in if let account=model.accountReference(id:id) { UsageAnalysisWindowController.shared.show(model:model,account:account) } }
                )
            case .stacked:
                IslandDetailStacked(
                    snapshots: model.detailSnapshots,
                    motionNamespace: reduceMotion ? nil : detailMotionNamespace,
                    focus: model.detailFocus,
                    officialReset: OfficialResetCardContent.make(officialResetCard.announcement, enabled: settings.officialResetAlertsEnabled),
                    officialResetLastChecked: officialResetCard.lastChecked,
                    officialResetError: officialResetCard.error,
                    onReserveOfficialReset: { officialResetCard.onReserve?($0) },
                    onOfficialPopoverChange: { officialResetCard.isPopoverPresented = $0 },
                    onContentHeightChange: { layout, size in receiveMeasuredHeight(size, layout: layout) },
                    onDisconnect: { requestPlatformRemoval($0) },
                    onSignIn: { platform in Task { await model.signIn(platform) } },
                    onReserveQuotaReset: { platform, row in model.reserveQuotaReset(platform: platform, row: row) },
                    onRefresh: { platform in
                        Task {
                            await model.refresh(platform)
                        }
                    },
                    onAccountDisconnect: { requestAccountRemoval($0) },
                    onAccountSignIn: { id in Task { await model.signInAccount(id: id) } },
                    onAccountRefresh: { id in Task { await model.refreshAccount(id: id) } },
                    onAccountReserveQuotaReset: { id, row in Task { await model.reserveQuotaReset(accountID: id, row: row) } },
                    onAccountAnalysis: { id in if let account=model.accountReference(id:id) { UsageAnalysisWindowController.shared.show(model:model,account:account) } }
                )
            }
        }
    }

    private var detailTitle: String {
        switch model.detailSnapshots.count {
        case 0: "选择账号"
        case 1: model.detailSnapshots.first?.title ?? "选择账号"
        default: "用量统计"
        }
    }

    // MARK: - 左下角平台管理

    @ViewBuilder private var removePlatformControl: some View {
        if !model.platformAccounts.enabled.isEmpty {
            platformControl(symbol: "minus.circle", title: "移除账号",
                            active: platformManagement.mode == .removing) {
                platformManagement.toggle(.removing)
            }
        }
    }

    @ViewBuilder private var addPlatformControl: some View {
        if !model.platformAccounts.enabled.isEmpty {
            platformControl(symbol: "plus.circle", title: "添加账号",
                            active: platformManagement.mode == .adding) {
                platformManagement.toggle(.adding)
            }
        }
    }

    private func platformControl(symbol: String, title: String, active: Bool,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.foreground.opacity(active ? 1 : 0.70))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(IslandFeedbackButtonStyle(circular: true, active: active))
        .help(title)
        .accessibilityLabel(title)
    }

    /// 使用面板内浮层，避免 nonactivatingPanel 中原生 Menu 显示空白。
    private var platformManagementPopup: some View {
        VStack(alignment: .leading, spacing: 0) {
            if case .confirmingRemoval(let platform) = platformManagement.mode {
                Text("移除 \(platform.title)？")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.foreground)
                    .padding(.bottom, 8)
                Text("将退出并清除该平台所有已保存账号的本机授权或登录状态，取消个人额度预约。以后可重新添加。")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.foreground.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
                HStack(spacing: 8) {
                    Button { platformManagement.dismiss() } label: {
                        Text("取消").padding(.horizontal, 10).padding(.vertical, 5)
                    }
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(role: .destructive) {
                        if let platform = platformManagement.confirmRemoval(in: model.platformAccounts) {
                            model.disconnect(platform)
                        }
                    } label: {
                        Text("确认移除").padding(.horizontal, 10).padding(.vertical, 5)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.foreground)
                .buttonStyle(IslandFeedbackButtonStyle())
            } else {
                let adding = platformManagement.mode == .adding
                Text(adding ? "添加账号" : "选择要移除的账号")
                    .font(.system(size: 9))
                    .foregroundStyle(palette.foreground.opacity(0.42))
                    .padding(.horizontal, 5)
                    .padding(.bottom, 4)
                if adding {
                    ForEach(platformManagement.candidates(in: model.platformAccounts)) { platform in
                        PlatformMenuRow(platform: platform, adding: true) {
                            if let selected = platformManagement.select(platform, in: model.platformAccounts) {
                                Task { await model.addAccount(platform: selected, label: "") }
                            }
                        }
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(model.orderedSavedAccounts) { account in
                                Button { requestAccountRemoval(account.id) } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: "minus.circle").font(.system(size: 10))
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(model.accountLabel(account)).font(.system(size: 11, weight: .medium))
                                                .lineLimit(1).truncationMode(.middle)
                                            Text(account.platform.title).font(.system(size: 9))
                                                .foregroundStyle(palette.foreground.opacity(0.5))
                                        }
                                        Spacer(minLength: 0)
                                    }.padding(7).contentShape(Rectangle())
                                }
                                .buttonStyle(IslandFeedbackButtonStyle())
                                .help("移除「\(model.accountLabel(account))」")
                                .accessibilityLabel("移除「\(model.accountLabel(account))」，\(account.platform.title)")
                            }
                        }
                    }.frame(height: min(CGFloat(model.savedAccounts.count) * 48, 240))
                }
            }
        }
        .padding(8)
        .frame(width: confirmationPlatform != nil ? 260 : platformManagement.mode == .adding ? 154 : 240, alignment: .leading)
        .background(palette.popup, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.foreground.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 10, y: 4)
    }

    private func requestPlatformRemoval(_ platform: UsagePlatform) {
        platformManagement.dismiss()
        platformManagement.toggle(.removing)
        _ = platformManagement.select(platform, in: model.platformAccounts)
    }
    private func requestAccountRemoval(_ id: String) {
        platformManagement.dismiss()
        accountRemoval = model.accountReference(id: id)
        confirmsAccountRemoval = accountRemoval != nil
    }

    private var confirmationPlatform: UsagePlatform? {
        if case .confirmingRemoval(let platform) = platformManagement.mode { return platform }
        return nil
    }

    // MARK: - 上报

    private func publishCompactSize(_ size: CGSize, layout: CompactLayout) {
        // 只挡 .zero 是不够的：NaN 和无穷大同样会流进面板 frame，
        // 后者会让窗口盖住整块屏幕。这里把非法值全部挡在门外。
        guard Self.isSane(size) else {
            NSLog("⚠️ 丢弃非法悬浮条尺寸 %@", "\(size)")
            return
        }
        DispatchQueue.main.async {
            // 排版可能在排队期间再次改变，写入前仍需校验归属。
            guard layout == settings.compactLayout else { return }
            guard abs(size.width - presentation.compactSize.width) > 0.5
                    || abs(size.height - presentation.compactSize.height) > 0.5 else { return }
            presentation.compactSize = size
        }
    }

    /// 渲染状态自检（RENDER-STATE）。
    ///
    /// 出现过「面板是黑的、没有内容」——黑底板画出来了但内容没渲染。
    /// 调试构建或显式启用临时诊断时，将关键状态滚动写入 render-state.log。
    /// 正式构建默认跳过格式化和文件访问。
    private func logRenderState(reason: String) {
        guard RenderStateLog.isEnabled else { return }
        let line = String(
            format: "RENDER-STATE [%@] mode=%@ compact=%.0fx%.0f detail=%.0fx%.0f "
                + "surface=%.0fx%.0f max=%.0fx%.0f snapshots=%d bar=%@/%.0f "
                + "detailLayout=%@ settings=%@ notch=%@ hBarW=%.0f topInset=%.0f screen=%.0fx%.0f",
            reason,
            String(describing: presentation.mode),
            compactSize.width, compactSize.height,
            detailSize.width, detailSize.height,
            surfaceSize.width, surfaceSize.height,
            maxSize.width, maxSize.height,
            model.snapshots.count,
            settings.compactLayout.rawValue, compactBarWidth,
            settings.detailLayout.rawValue,
            presentation.showingSettings ? "on" : "off",
            presentation.hasNotch ? "yes" : "no",
            presentation.horizontalBarWidth,
            presentation.topInset,
            presentation.screenWidth, presentation.screenHeight)
        RenderStateLog.append(line)
    }

    /// 实测尺寸是否可用：有限、为正、且不超过上限。
    static func isSane(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite
            && size.width > 1 && size.height > 1
            && size.width <= maxMeasuredSide && size.height <= maxMeasuredSide
    }

    /// 按实测尺寸更新面板。
    ///
    /// 这里必须比**整个尺寸**而不是只比高度：早期版本只比高度，
    /// 于是「宽度变了、高度没变」的切换（换排版、加减平台）不会刷新面板宽度，
    /// 结果面板比内容窄，卡片左右被裁掉。
    /// 收到实测高度。
    ///
    /// 排版切换时**立刻**按策略写入悬浮条尺寸。
    ///
    /// 不能等测量：实测发现 SwiftUI 有时不重新派发偏好值，
    /// `onPreferenceChange` 不触发，尺寸就永远停在旧排版——
    /// 横向条 565 宽却只露出中间 200 pt（那段恰好是 Spacer 空白），
    /// 看起来就是「一块黑的、没有内容」。
    /// 宽度本来就完全由排版决定，直接写即可；高度取该排版自己的缓存值。
    ///
    /// 由 AppDelegate 的 Combine 订阅调用（`onChange` 在展开态切过去时实测不可靠），
    /// 且**传入订阅收到的排版值**，不读 `settings`（willSet 阶段属性还是旧值）。
    /// 收到悬浮条实测尺寸。
    ///
    /// 按**上报方声明的排版**归属，并且只发布当前排版的测量：
    /// 切换排版时旧排版的测量会迟到，用它去覆盖会把刚改对的面板尺寸打回旧值。
    private func receiveCompactSize(_ size: CGSize, layout: CompactLayout) {
        guard Self.isSane(size) else { return }
        presentation.compactHeights[layout.rawValue] = size.height
        guard layout == settings.compactLayout else { return }
        publishCompactSize(size, layout: layout)
    }

    /// 收到实测高度，记到**当前排版**名下。
    private func receiveMeasuredHeight(_ size: CGSize, layout: DetailLayout) {
        guard size.height > 0, size.height < Self.maxMeasuredSide else { return }
        let key = layout.rawValue
        // 在布局过程中写 @State 会触发「Modifying state during view update」，
        // 所以推迟一拍；发布本身不受影响。
        DispatchQueue.main.async {
            if abs(size.height - (presentation.detailHeights[key] ?? -1)) > 0.5 {
                presentation.detailHeights[key] = size.height
            }
            // 行高未变也必须更新策略宽度（例如双平台移除一个后）。
            // 迟到的旧排版测量只更新缓存，不改面板
            guard layout == settings.detailLayout else { return }
            publishDetailSize()
        }
    }

    /// 重算并发布面板尺寸。
    ///
    /// 面板**宽度是策略推导的**（按平台数 / 排版取 360 / 565 / 722），
    /// 与实测无关；高度才来自实测。所以排版一变就必须立刻重算——
    /// 早期只挂在「有新测量」这一个入口上，导致排版切换后
    /// 宽度永远停在旧值（面板 360 宽而卡片 565 宽，内容左右被裁掉）。
    private func publishDetailSize() {
        let next = presentation.detailSize(for: settings.detailLayout,
                                           platformCount: model.detailSnapshots.count)
        let current = presentation.detailSize
        guard abs(next.width - current.width) > 0.5
                || abs(next.height - current.height) > 0.5 else { return }
        presentation.detailSize = next
    }
}

/// 没有任何平台时的选择页。
struct PlatformPickerView: View {
    @Environment(\.colorScheme) private var colorScheme
    private var palette: IslandPalette { IslandPalette(scheme: colorScheme) }
    let onPick: (UsagePlatform) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(IslandBrand.name.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.3)
                    .foregroundStyle(palette.foreground.opacity(0.40))
                Text("选择要登录的平台")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.foreground.opacity(0.82))
            }
            ForEach(UsagePlatform.allCases) { platform in
                Button { onPick(platform) } label: {
                    HStack {
                        Text(platform.title)
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.foreground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(palette.foreground.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            Text("DeepSeek 显示余额与用量；智谱、ChatGPT 显示订阅额度。")
                .font(.system(size: 10))
                .foregroundStyle(palette.foreground.opacity(0.46))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


private struct PlatformMenuRow: View {
    @Environment(\.colorScheme) private var colorScheme
    private var palette: IslandPalette { IslandPalette(scheme: colorScheme) }
    let platform: UsagePlatform
    let adding: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: adding ? "plus.circle" : "minus.circle")
                    .font(.system(size: 9))
                Text(platform.title).font(.system(size: 11))
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovered ? palette.foreground : palette.foreground.opacity(0.82))
            .padding(.horizontal, 5)
            .padding(.vertical, 7)
            .background(hovered ? palette.foreground.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(adding ? "添加" : "移除") \(platform.title)")
    }
}
