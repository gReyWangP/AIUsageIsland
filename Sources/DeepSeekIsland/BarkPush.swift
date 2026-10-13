import Foundation
import Combine
import SwiftUI

struct BarkPushError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private final class BarkRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class BarkPushService: ObservableObject {
    @Published private(set) var status: String?
    @Published private(set) var manualStatus: String?
    @Published private(set) var sending = false
    private let session = URLSession(configuration: .ephemeral, delegate: BarkRedirectGuard(), delegateQueue: nil)

    private let transport: ((URLRequest) async throws -> (Data, URLResponse))?
    init(transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) { self.transport = transport }

    static func request(address: String, title: String, body: String) throws -> URLRequest {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              !url.lastPathComponent.isEmpty, url.lastPathComponent != "/", url.lastPathComponent != "push" else {
            throw BarkPushError("请填写完整的 HTTPS Bark 推送地址，例如 https://api.day.app/设备Key")
        }
        var request = URLRequest(url: url.deletingLastPathComponent().appendingPathComponent("push"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_key": url.lastPathComponent, "title": title, "body": body, "group": "AIUsageIsland"
        ])
        return request
    }
    static func validateResponse(_ data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? Int, code == 200 else {
            throw BarkPushError("Bark 推送未成功，请检查推送地址和服务器状态。")
        }
    }
    func send(address: String, title: String, body: String) async throws {
        let request = try Self.request(address: address, title: title, body: body)
        do {
            let result: (Data, URLResponse)
            if let transport { result = try await transport(request) }
            else { result = try await session.data(for: request) }
            let (data, response) = result
            try Self.validateResponse(data, response: response)
        } catch {
            // Network errors may contain the address/key. Keep UI errors generic.
            throw BarkPushError("Bark 推送失败，请检查推送地址、网络和服务器状态。")
        }
    }
    static func addresses(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    func sendAll(addresses: String, title: String, body: String, allowed: (String) -> Bool = { _ in true }, progress: (String) -> Void = { _ in }) async throws {
        status = nil
        let targets = Self.addresses(addresses)
        guard !targets.isEmpty else { throw BarkPushError("请至少填写一个推送地址。") }
        // Validate the whole list before sending anything.
        for address in targets { _ = try Self.request(address: address, title: title, body: body) }
        var accepted = 0
        var failed = 0
        var cancelled = 0
        var results: [String] = []
        for (index, address) in targets.enumerated() {
            guard allowed(address) else { cancelled += 1; results.append("地址 \(index + 1)：已取消"); continue }
            progress("发送中：正在发送地址 \(index + 1)/\(targets.count)…")
            do {
                try await send(address: address, title: title, body: body)
                accepted += 1; results.append("地址 \(index + 1)：服务器已接受")
            } catch { failed += 1; results.append("地址 \(index + 1)：发送失败，请检查地址和网络") }
        }
        let result = accepted == targets.count ? "发送成功" : accepted > 0 ? "部分发送成功" : cancelled == targets.count ? "发送已取消" : "发送失败"
        status = result + "：成功 \(accepted)，失败 \(failed)，取消 \(cancelled)。\n"
            + results.joined(separator: "\n") + "\n完成时间：" + Date.now.formatted(date: .omitted, time: .standard)
            + "\n成功表示服务器已接受，请在手机确认通知。"
        progress(status!)
        if accepted == 0 { throw BarkPushError("所有地址均发送失败，请检查地址和网络。") }
    }
    func sendDigest(addresses: String, events: [OfficialResetAnnouncement]) async {
        guard !sending else { return }
        guard !events.isEmpty else { manualStatus = "没有可推送的动态，请先加载今日重置动态。"; return }
        guard events.allSatisfy({ Calendar.current.isDateInToday($0.announcedAt) && $0.announcedAt <= .now }) else {
            manualStatus = "日期已变化，请重新加载今日动态。"; return
        }
        sending = true
        manualStatus = "手动动态推送：正在检查地址…"
        defer { sending = false }
        let body = "推送原因：你手动推送了今日重置动态。\n\n" + events.map(\.pushSummary).joined(separator: "\n\n────────\n\n")
        do {
            try await sendAll(addresses: addresses, title: "今日重置动态 · \(events.count) 条", body: body,
                progress: { self.manualStatus = "手动动态推送 · " + $0 })
        } catch { if status == nil { manualStatus = "手动动态推送失败：" + error.localizedDescription } }
    }
    func sendTest(address: String) async {
        guard !sending else { return }
        sending = true
        manualStatus = "连接通知：正在检查地址…"
        defer { sending = false }
        do {
            try await sendAll(addresses: address, title: "AIUsageIsland 推送连接", body: "手机推送已连接。",
                progress: { self.manualStatus = "连接通知 · " + $0 })
        } catch { if status == nil { manualStatus = "连接通知发送失败：" + error.localizedDescription } }
    }
}

struct BarkPushSettingsView: View {
    @ObservedObject var settings: IslandSettings
    @ObservedObject var service: BarkPushService
    @ObservedObject var monitor: OfficialResetMonitor
    @State private var today: [OfficialResetAnnouncement] = []
    @State private var loading = false
    @State private var loadStatus: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("开启 Bark 手机推送", isOn: $settings.barkPushEnabled)
            if service.sending { ProgressView("正在发送，请稍候…").controlSize(.small) }
            if let manualStatus = service.manualStatus {
                Text(manualStatus).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(settings.barkPushAddresses.indices, id: \.self) { index in
                HStack {
                    TextField("https://api.day.app/设备Key", text: Binding(get: {
                        settings.barkPushAddresses.indices.contains(index) ? settings.barkPushAddresses[index] : ""
                    }, set: { value in
                        var values = settings.barkPushAddresses
                        guard values.indices.contains(index) else { return }
                        values[index] = value; settings.barkPushAddresses = values
                    })).textFieldStyle(.roundedBorder).disabled(service.sending)
                    Button("移除") {
                        var values = settings.barkPushAddresses
                        if values.indices.contains(index) { values.remove(at: index) }
                        settings.barkPushAddresses = values.isEmpty ? [""] : values
                    }.disabled(service.sending)
                }
            }
            Button("添加推送地址") { settings.barkPushAddresses += [""] }.disabled(service.sending)
            Button(service.sending ? "发送中…" : "发送连接通知") { Task { await service.sendTest(address: settings.barkPushAddress) } }
                .disabled(service.sending || settings.barkPushAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(loading ? "正在加载…" : "加载今日重置动态") {
                Task {
                    loading = true; today = []; loadStatus = nil
                    defer { loading = false }
                    do {
                        today = try await monitor.todayForPush()
                        loadStatus = today.isEmpty ? "当前来源没有今日发布的重置动态，不会发送空消息。" : "已加载 \(today.count) 条，确认内容后可手动推送。"
                    } catch { loadStatus = "动态加载失败，请稍后重试。" }
                }
            }.disabled(loading || service.sending)
            if let loadStatus { Text(loadStatus).font(.footnote).foregroundStyle(.secondary) }
            if !today.isEmpty {
                ScrollView { Text(today.map(\.pushSummary).joined(separator: "\n\n────────\n\n"))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 160)
                Button("手动推送今日动态（\(today.count) 条）") {
                    Task { await service.sendDigest(addresses: settings.barkPushAddress, events: today) }
                }.disabled(service.sending || loading || BarkPushService.addresses(settings.barkPushAddress).isEmpty)
            }
            Text("今日按本机日期筛选。来源接口仅提供最新动态及预告，可能不含当天全部历史。手动推送可在自动推送关闭时使用，再次点击会再次发送。")
                .font(.caption).foregroundStyle(.secondary)
            if service.manualStatus == nil, let status = service.status {
                Text(status).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("填写 Bark 中复制的完整推送地址，支持自建 HTTPS 服务。自动推送仅包含新重置动态，遵循“Codex 重置公告”开关、提醒时段和暂停设置；无需开启账号额度提醒。Mac 应用需运行且联网。")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("地址仅保存在本机，不随配置导出。Bark 只发送公开重置动态和主动发送的连接通知，不发送本机账号名称、余额或额度。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
