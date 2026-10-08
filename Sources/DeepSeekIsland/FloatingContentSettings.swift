import SwiftUI

/// Metric preferences apply to every account of that platform; account ordering has one owner.
struct FloatingContentSettings: View {
    @ObservedObject var settings: IslandSettings
    @ObservedObject var model: IslandModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("全屏时暂停自动悬停展开", isOn: $settings.pausesHoverInFullscreen)
            Divider()
            Text("悬浮指标").fontWeight(.semibold)
            Text("同平台的账号共用指标选择，至少保留一项。明细始终显示完整数据；显示账号和顺序在“账号与显示”中设置。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(UsagePlatform.allCases) { platform in
                let snapshot = model.snapshot(for: platform)
                let allIDs = snapshot.compactMetrics.map(\.id)
                let selected = settings.visibleMetricIDs(for: platform, allIDs: allIDs)
                VStack(alignment: .leading, spacing: 8) {
                    Text(platform.title).fontWeight(.semibold)
                    ForEach(snapshot.compactMetrics) { metric in
                        Toggle(metric.label, isOn: Binding(get: { settings.visibleMetricIDs(for: platform, allIDs: allIDs).contains(metric.id) }, set: {
                            settings.setCompactMetric(metric.id, visible: $0, for: platform, allIDs: allIDs)
                        })).disabled(selected.count == 1 && selected.contains(metric.id))
                    }
                }.padding(12).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            }
            Button("恢复默认指标") { settings.compactMetricSelection = [:] }
        }.font(.system(size: 11)).toggleStyle(SettingsToggleStyle())
    }
}
