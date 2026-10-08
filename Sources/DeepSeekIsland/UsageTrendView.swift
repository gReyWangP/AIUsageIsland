import Charts
import SwiftUI

struct UsageTrendView: View {
    @ObservedObject var runtime: AccountRuntime
    let accountName: String
    @ObservedObject var history: UsageTrendStore
    @Environment(\.dismiss) private var dismiss
    @State private var days = 1
    @State private var metric: UsageMetric
    private let embedded: Bool
    init(runtime: AccountRuntime, accountName: String, embedded: Bool = false) {
        self.runtime = runtime; self.accountName = accountName; history = runtime.trend
        self.embedded = embedded
        _metric = State(initialValue: .defaultMetric(for: runtime.account.platform))
    }
    private var points: [UsageTrendPoint] {
        let values = history.recent(metric: metric, days: days)
        guard metric == .deepSeekBalance, let unit = values.last?.unit else { return values }
        return values.filter { $0.unit == unit }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !embedded {
                HStack { Text(accountName + " · 本地额度趋势").font(.title3).fontWeight(.semibold); Spacer(); Button("关闭") { dismiss() } }
            }
            Picker("指标", selection: $metric) {
                ForEach(runtime.capabilities.availableMetrics) { Text($0.windowLabel).tag($0) }
            }
            Picker("时间范围", selection: $days) { Text("24 小时").tag(1); Text("7 天").tag(7) }.pickerStyle(.segmented)
            if points.isEmpty {
                Text("暂无有效历史。应用会从之后的成功刷新开始记录；无限制窗口不会生成数值采样。")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart(points) { point in
                    LineMark(x: .value("时间", point.timestamp), y: .value("数值", point.value), series: .value("分段", point.segment))
                        .foregroundStyle(.blue)
                    PointMark(x: .value("时间", point.timestamp), y: .value("数值", point.value)).foregroundStyle(.blue)
                }.chartLegend(.hidden).frame(minHeight: 240)
                Text(metric == .deepSeekBalance ? "余额（\(points.last?.unit ?? runtime.currency)）" : "已用额度（%）")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("只记录本机成功获取的数据。重置、额度补发和长时间缺口会分段，不能据此推算精确 Token 或请求次数。保留最近 7 天，最多 4000 个采样点。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = history.persistenceError { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            if let last = points.last {
                Text("本机采样 · 最近记录：" + last.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size:11)).foregroundStyle(.secondary)
            }
        }.padding(embedded ? 0 : 22).frame(width: embedded ? nil : 620, height: embedded ? nil : 440)
    }
}
