import SwiftUI

struct IslandPinButton: View {
    @Binding var pinned: Bool
    @Environment(\.colorScheme) private var colorScheme
    private var palette: IslandPalette { IslandPalette(scheme: colorScheme) }

    var body: some View {
        Button { pinned.toggle() } label: {
                HStack(spacing: 3) {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                    if pinned { Text("已固定").font(.system(size: 9)) }
                }
                .foregroundStyle(pinned ? palette.accent : palette.foreground.opacity(0.8))
                .padding(.horizontal, pinned ? 6 : 0)
                .frame(height: 16)

        }
        .buttonStyle(IslandFeedbackButtonStyle(active: pinned))
        .help(pinned ? "取消固定" : "固定详情")
    }
}


/// 自定义悬浮面板中的按钮反馈不依赖原生窗口的激活状态。
struct IslandFeedbackButtonStyle: ButtonStyle {
    var circular = false
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        IslandFeedbackButtonBody(configuration: configuration, circular: circular, active: active)
    }
}

private struct IslandFeedbackButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let circular: Bool
    let active: Bool
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var palette: IslandPalette { IslandPalette(scheme: colorScheme) }
    private var highlighted: Bool { enabled && (hovered || configuration.isPressed) }
    private var tint: Color {
        configuration.role == .destructive ? .red : palette.accent
    }
    private var fill: Color {
        if highlighted { return tint.opacity(configuration.isPressed ? 0.32 : 0.22) }
        if active { return palette.accent.opacity(0.16) }
        return palette.foreground.opacity(0.07)
    }

    var body: some View {
        configuration.label
            .background {
                if circular { Circle().fill(fill) }
                else { RoundedRectangle(cornerRadius: 6).fill(fill) }
            }
            .overlay {
                if circular {
                    Circle().stroke(highlighted ? tint.opacity(0.65) : .clear, lineWidth: 1)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(highlighted ? tint.opacity(0.65) : .clear, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .scaleEffect(enabled && configuration.isPressed ? 0.96 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: highlighted)
            .onHover { hovered = enabled && $0 }
    }
}
