import SwiftUI

/// One button owns the header, so the arrow, title and trailing space toggle exactly once.
struct SettingsDisclosureGroupStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 10)
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "已展开" : "已收起")
            if configuration.isExpanded {
                configuration.content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Keep the native indicator while giving its complete label row one shared action.
/// The indicator is decorative here: it cannot separately fire and toggle the binding twice.
struct SettingsToggleStyle: ToggleStyle {
    var switchControl = false
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                indicator(configuration)
                    .allowsHitTesting(false)
                    .focusable(false)
                    .accessibilityHidden(true)
                configuration.label
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "已开启" : "已关闭")
        .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
    }
    @ViewBuilder private func indicator(_ configuration: Configuration) -> some View {
        if switchControl {
            Toggle("", isOn: configuration.$isOn).labelsHidden().toggleStyle(.switch)
        } else {
            Toggle("", isOn: configuration.$isOn).labelsHidden().toggleStyle(.checkbox)
        }
    }
}
