import AppKit
import Combine
import SwiftUI

/// 原生快速上手：示意数据不代表账号的实时用量。
struct IslandGuideView: View {
    @ObservedObject var settings: IslandSettings
    var onFinish: () -> Void
    @Environment(\.colorScheme) private var systemScheme
    private var scheme: ColorScheme { settings.appearanceMode.colorScheme ?? systemScheme }
    private var palette: IslandPalette { IslandPalette(scheme: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                IslandLogoMark(size: 48)
                VStack(alignment: .leading, spacing: 5) {
                    Text("欢迎使用 AIUsageIsland")
                        .font(.system(size: 23, weight: .semibold, design: .rounded))
                    Text("在 Mac 顶部，随时查看 AI 账号的余额与额度。")
                        .font(.system(size: 12)).foregroundStyle(palette.foreground.opacity(0.6))
                }
            }
            HStack {
                Text("快速上手").font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("图中为示例数据").font(.system(size: 10))
            }
            .foregroundStyle(palette.foreground.opacity(0.55))
            VStack(spacing: 10) {
                card("01", "添加账号", text: "在详情左下角点击 ＋ 登录账号，同一个平台也可以添加多个账号。") {
                    platformIllustration
                }
                card("02", "查看用量", text: "鼠标移到刘海或屏幕顶部中央查看，点击浮窗展开余额、额度和重置时间。") {
                    notchIllustration
                }
                card("03", "菜单栏速览", text: "菜单栏圆环可显示所选账号的剩余额度；点击即可打开详情，也可在设置中调整。") {
                    menuBarIllustration
                }
            }
            Text("显示账号、布局和提醒，可随时在设置中调整。")
                .font(.system(size: 11)).foregroundStyle(palette.foreground.opacity(0.6))
            Spacer(minLength: 0)
            HStack {
                Text("开始使用后不再自动显示，可在设置中重新打开。")
                    .font(.system(size: 11)).foregroundStyle(palette.foreground.opacity(0.6))
                Spacer()
                Button("开始使用") {
                    settings.completeStartupGuide()
                    onFinish()
                }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .foregroundStyle(palette.foreground)
        .padding(24)
        .frame(width: 560, height: 500)
        .background(palette.settings)
        .environment(\.colorScheme, scheme)
        .preferredColorScheme(settings.appearanceMode.colorScheme)
    }

    private func card<Graphic: View>(_ number: String, _ title: String, text: String,
                                     @ViewBuilder graphic: () -> Graphic) -> some View {
        HStack(spacing: 14) {
            graphic().frame(width: 150, height: 60).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Text(number).font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.accent)
                    Text(title).font(.system(size: 13, weight: .semibold))
                }
                Text(text).font(.system(size: 11)).lineSpacing(3)
                    .foregroundStyle(palette.foreground.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).frame(height: 88)
        .background(palette.foreground.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(palette.foreground.opacity(0.08), lineWidth: 1))
    }

    private var notchIllustration: some View {
        VStack(spacing: 5) {
            VStack(spacing: 4) {
                UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)
                    .fill(Color.black).frame(width: 50, height: 14)
                Text("5 小时剩余 83%").font(.system(size: 10, weight: .medium))
            }
            .frame(width: 136).padding(.bottom, 6)
            .background(palette.surface, in: UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9))
            Label("移到顶部 → 点击展开", systemImage: "cursorarrow")
                .font(.system(size: 9)).foregroundStyle(palette.accent)
        }
    }

    private var platformIllustration: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.circle.fill").font(.system(size: 21)).foregroundStyle(palette.accent)
            logo("DeepSeekLogo", ext: "svg")
            logo("CodingPlanLogo", ext: "png")
            logo("ChatGPTLogo", ext: "png")
        }
    }

    private func logo(_ name: String, ext: String) -> some View {
        Group {
            if let url = IslandResources.bundle?.url(forResource: name, withExtension: ext), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().renderingMode(.template).scaledToFit().frame(width: 25, height: 25)
            }
        }
    }

    private var menuBarIllustration: some View {
        HStack(spacing: 10) {
            Image(nsImage: MenuBarRenderer.image(platform: .chatGPT, data: .quota(remaining: 83), dark: scheme == .dark))
            VStack(alignment: .leading, spacing: 4) {
                Text("ChatGPT").font(.system(size: 10, weight: .medium))
                Text("剩余 83%").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(10).background(palette.surface, in: RoundedRectangle(cornerRadius: 9))
    }
}

@MainActor
final class IslandGuideController: NSObject, NSWindowDelegate {
    private let settings: IslandSettings
    private let onFinish: () -> Void
    private var window: NSWindow?
    private var appearanceSubscription: AnyCancellable?
    var isVisible: Bool { window?.isVisible == true }

    init(settings: IslandSettings, onFinish: @escaping () -> Void) {
        self.settings = settings
        self.onFinish = onFinish
        super.init()
        appearanceSubscription = settings.$appearanceMode.sink { [weak self] mode in
            self?.window?.appearance = mode.nsAppearance
        }
    }

    func reposition() {
        guard let window, window.isVisible,
              let screen = ScreenTarget.screen(for: settings.screenSelection, in: NSScreen.screens,
                retaining: window.screen.map { ScreenTarget.displayID(of: $0) }) else { return }
        let frame = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
    }

    func show() {
        if window == nil {
            let root = IslandGuideView(settings: settings) { [weak self] in self?.window?.close() }
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "AIUsageIsland · 使用引导"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 560, height: 500))
            window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        } else {
            // 手动重新打开不重置引导完成状态或旧版偏好。
            window?.contentViewController = NSHostingController(rootView:
                IslandGuideView(settings: settings) { [weak self] in self?.window?.close() })
            window?.setContentSize(NSSize(width: 560, height: 500))
        }
        guard let window else { return }
        window.appearance = settings.appearanceMode.nsAppearance
        window.backgroundColor = .windowBackgroundColor
        if let screen = ScreenTarget.screen(for: settings.screenSelection, in: NSScreen.screens) {
            let frame = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2,
                                          y: frame.midY - window.frame.height / 2))
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onFinish()
    }
}
