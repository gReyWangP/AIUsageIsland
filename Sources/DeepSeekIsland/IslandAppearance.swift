import AppKit
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    var title: String {
        switch self { case .light: "浅色"; case .dark: "深色"; case .system: "跟随系统" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .light: .light; case .dark: .dark; case .system: nil }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }
}

enum BackgroundEffect: String, CaseIterable, Identifiable {
    case solid, glass
    var id: String { rawValue }
    var title: String { self == .solid ? "纯色" : "毛玻璃" }
    func resolved(reduceTransparency: Bool) -> BackgroundEffect {
        reduceTransparency ? .solid : self
    }
}

/// 统一使用随外观解析的颜色，保留原有深色值。
struct IslandPalette {
    let scheme: ColorScheme
    var foreground: Color { scheme == .dark ? .white : .black }
    var surface: Color { scheme == .dark ? .black : Color(white: 0.97) }
    var settings: Color { Color(white: scheme == .dark ? 0.09 : 0.97) }
    var popup: Color { Color(white: scheme == .dark ? 0.14 : 0.94) }
    var accent: Color {
        scheme == .dark ? Color(red: 0.53, green: 0.68, blue: 1)
                        : Color(red: 0.18, green: 0.36, blue: 0.76)
    }
}

/// 原生窗口背后模糊：不仅降低不透明度，而是模糊桌面和其它窗口。
struct IslandVisualEffect: NSViewRepresentable {
    let colorScheme: ColorScheme

    static func makeEffectView(colorScheme: ColorScheme) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        return view
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        Self.makeEffectView(colorScheme: colorScheme)
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    }
}

struct IslandBackground: View {
    let effect: BackgroundEffect
    var settingsWindow = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let palette = IslandPalette(scheme: colorScheme)
        let color = settingsWindow ? palette.settings : palette.surface
        if effect.resolved(reduceTransparency: reduceTransparency) == .glass {
            IslandVisualEffect(colorScheme: colorScheme)
                // 材质本身已提供可读性底色，仅保留轻微主题染色。
                .overlay(color.opacity(colorScheme == .dark ? 0.10 : 0.06))
                .allowsHitTesting(false)
        } else {
            color
        }
    }
}

/// 在同一个根视图内观察设置，颜色变化不会替换内容或丢失菜单状态。
struct IslandAppearanceRoot<Content: View>: View {
    @ObservedObject var settings: IslandSettings
    let content: Content

    var body: some View {
        content.preferredColorScheme(settings.appearanceMode.colorScheme)
    }
}


struct IslandSettingsBackground: View {
    @ObservedObject var settings: IslandSettings
    var body: some View {
        IslandBackground(effect: settings.backgroundEffect, settingsWindow: true)
            .ignoresSafeArea()
    }
}
