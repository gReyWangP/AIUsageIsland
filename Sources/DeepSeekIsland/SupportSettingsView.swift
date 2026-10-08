import SwiftUI

struct SupportSettingsView: View {
    private enum Page: String, Identifiable {
        case privacy = "隐私与本机数据"
        case notes = "版本说明"
        case feedback = "反馈与支持"
        var id: String { rawValue }
    }
    @State private var page: Page?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("关于 AIUsageIsland").font(.headline)
            Text("版本 " + IslandBrand.version).foregroundStyle(.secondary)
            Text("独立第三方 AI 账号用量速览工具；ChatGPT 页面展示 Codex 额度，不代表聊天用量。")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("隐私说明") { page = .privacy }
                Button("版本说明") { page = .notes }
                Button("反馈与支持") { page = .feedback }
            }
        }.sheet(item: $page) { selected in
            VStack(alignment: .leading, spacing: 16) {
                Text(selected.rawValue).font(.title2)
                ScrollView { Text(content(selected)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                HStack { Spacer(); Button("关闭") { page = nil }.keyboardShortcut(.cancelAction) }
            }.padding(24).frame(width: 520, height: 520)
        }
    }

    private func content(_ page: Page) -> String {
        switch page {
        case .privacy:
            "本地测试版的账号授权保存在应用自身数据目录中，并限制文件访问权限；智谱网页会话使用各账号独立的 WebKit 存储。当前尚未迁移到 Keychain。\n\n应用会向所选平台发送授权并请求余额、额度及官方日统计；不读取其他客户端的凭据。平台仍按其自己的规则处理请求。\n\nCodex 重置公告默认订阅，向第三方 Codex Resets 请求公开公告，通常每 15 分钟检查一次；可在提醒设置关闭。公告不代表个人额度已经恢复。\n\n本机额度采样保留最近 7 天、最多 4000 点，官方日统计保留最多 90 天。详细渲染日志在正式构建中默认关闭，临时诊断最多保留 200 条。\n\n账号管理中的移除操作用于清理对应的本机授权和历史。显示隐藏不会删除账号。导出配置不包含凭据，也不恢复系统权限或自动启用登录项。\n\n匿名诊断仅含平台、序号、更新时间和结构化状态，不包含账号名称、Token、Cookie 或响应正文。只有主动复制后才进入剪贴板。"
        case .notes:
            "本地测试版\n\n• 新安装默认显示菜单栏，公告订阅默认开启。\n• 开始使用后，引导不再自动出现；设置中仍可打开。\n• 用量分析共用账号选择，可切换消耗统计与额度变化。\n• 账号异常显示对应的恢复动作，额度与日统计状态分开。\n• 设置分为账号、外观、提醒、通用与支持。\n• 历史在后台保存，磁盘失败保留内存；退出最多等待 3 秒，超时可能丢失最新未保存数据。\n\n已有账号、提醒规则、显示组合和手动选择继续保留。"
        case .feedback:
            "反馈时请提供应用版本、macOS 版本、复现步骤以及预期与实际结果。可在通用与支持复制匿名诊断。\n\n请勿发送账号授权文件、Token、Cookie 或未匿名化的用量响应。\n\n当前为本地测试版，公开下载页和正式反馈渠道尚未配置。更新通过获取新的测试应用包完成，暂不自动下载更新。\n\n通知提交成功不代表系统一定显示横幅；请同时检查系统通知样式、专注模式和屏幕共享期间的通知设置。"
        }
    }
}
