import SwiftUI

struct AccountSettingsView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject var model: IslandModel
    @ObservedObject var settings: IslandSettings
    var initiallyExpanded = false
    @State private var managing: AccountReference?
    @State private var removal: AccountReference?
    @State private var confirmsRemoval = false
    @State private var adding = false
    @State private var label = ""
    @State private var platform = UsagePlatform.deepSeek
    @State private var openCodeGoKey = ""
    @State private var keyAccount: AccountReference?
    @State private var keyText = ""
    @State private var keyConnecting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("你的账号").fontWeight(.semibold)
                    Spacer()
                    Text("\(model.visibleAccounts.count) / 4").foregroundStyle(.secondary).monospacedDigit()
                }
                Text("勾选要显示的账号，用箭头调整顺序。悬浮和明细共用此选择；取消勾选会保留登录。")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(model.orderedSavedAccounts) { account in accountRow(account) }
                if model.savedAccounts.isEmpty { Text("尚未添加账号").foregroundStyle(.secondary) }
                Button { adding.toggle(); label = ""; openCodeGoKey = "" } label: { Label("添加账号", systemImage: "plus") }
                if adding {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("平台", selection: $platform) {
                            ForEach(UsagePlatform.allCases) { Text($0.title).tag($0) }
                        }
                        TextField(model.platformAccounts.enabled.contains(platform) ? model.accountProfiles.nextLabel(for: platform) : platform.title, text: $label)
                            .textFieldStyle(.roundedBorder)
                        if platform == .antigravity {
                            Text("云端登录不要求 Antigravity 运行；本机读取会从正在运行的 Antigravity 语言服务获取额度。两种方式都包含 Gemini 与 Claude/GPT 的 5 小时／周额度。")
                                .font(.footnote).foregroundStyle(.secondary)
                            HStack {
                                Button("登录 Google 账号") {
                                    let chosenLabel = label
                                    adding = false; label = ""
                                    Task { await model.addAntigravityAccount(label: chosenLabel, source: .cloud) }
                                }.disabled(model.antigravitySigningIn || model.antigravityLoading)
                                Button("从本机读取") {
                                    let chosenLabel = label
                                    adding = false; label = ""
                                    Task { await model.addAntigravityAccount(label: chosenLabel, source: .local) }
                                }.disabled(model.antigravitySigningIn || model.antigravityLoading)
                                Button("取消") { adding = false }
                            }
                            Text("云端令牌只保存在本机；本机读取不会复制 Antigravity 的账号凭据。")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else if platform == .openCodeGo {
                            SecureField("OpenCode API Key（Go 订阅，不是 Zen 余额 Key）", text: $openCodeGoKey)
                                .textFieldStyle(.roundedBorder)
                            HStack {
                                Button("打开 OpenCode Console") { openURL(UsagePlatform.openCodeGo.officialUsageURL) }
                                Spacer()
                                Button("连接 OpenCode") {
                                    let chosenLabel = label, key = openCodeGoKey
                                    adding = false; label = ""; openCodeGoKey = ""
                                    Task { await model.addOpenCodeGoAccount(label: chosenLabel, apiKey: key) }
                                }.disabled(openCodeGoKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || model.openCodeGoSigningIn)
                                Button("取消") { adding = false; openCodeGoKey = "" }
                            }
                            Text("在 OpenCode Console 登录并订阅 Go 后复制 Go API Key；Key 只保存在本机。连接后的用量分析读取本机 OpenCode 记录，仅限此 Mac，可能与云端统计有差异。")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            HStack {
                                Button("开始登录") {
                                    let chosenPlatform = platform, chosenLabel = label
                                    adding = false; label = ""
                                    Task { await model.addAccount(platform: chosenPlatform, label: chosenLabel) }
                                }.disabled(model.isSigningIn || model.chatGPTSigningIn || model.zhipuSigningIn)
                                Button("取消") { adding = false }
                            }
                        }
                        Text("名称可以留空，自动使用平台名及编号。登录成功后有空位就加入显示，已满则保存为隐藏账号。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.padding(12).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                }
                if let error = model.accountManagementError { Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                Text("DeepSeek、ChatGPT、Antigravity 使用系统浏览器授权。添加其他账号时，请在授权页切换到目标账号；ChatGPT 返回已保存账号时会阻止重复添加。智谱各账号使用独立网页登录空间；OpenCode 使用 Go 订阅的 API Key，在官方控制台登录后复制；Antigravity 可登录 Google 账号从云端读取，也可从正在运行的本机语言服务读取。")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.settingsCard()
                AccountMenuBarSettingsView(model: model, settings: settings).settingsCard()
                if model.savedAccounts.count > 1 || !model.displayPresets.isEmpty {
                    DisplayPresetSettingsView(model: model, settings: settings).settingsCard()
                } else {
                    DisclosureGroup("高级账号显示") {
                        DisplayPresetSettingsView(model: model, settings: settings).padding(.top, 8)
                    }.settingsCard()
                }
                Text("每个账号的额度提醒在“提醒”中分别设置。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(.trailing, 5)
        }
        .font(.callout)
        .confirmationDialog("移除 \(removal.map(model.accountLabel) ?? "这个账号")？", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("移除「\(removal.map(model.accountLabel) ?? "这个账号")」", role: .destructive) {
                if let removal { Task { await model.removeAccount(removal) } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅清除这个账号的本机授权与用量记录；其他账号保留。")
        }
        .sheet(item: $keyAccount) { account in
            VStack(alignment: .leading, spacing: 12) {
                Text("连接 OpenCode").font(.headline)
                Text("在 OpenCode Console 登录并订阅 Go 后复制 Go 订阅 API Key（不是 Zen 余额 Key）。")
                    .font(.footnote).foregroundStyle(.secondary)
                SecureField("OpenCode API Key", text: $keyText)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("打开 OpenCode Console") { openURL(UsagePlatform.openCodeGo.officialUsageURL) }
                    Spacer()
                    Button("取消") { keyAccount = nil; keyText = "" }
                    Button("连接") {
                        let key = keyText
                        keyConnecting = true
                        Task {
                            await model.connectOpenCodeGo(account: account, apiKey: key)
                            keyConnecting = false
                            if model.accountRuntime(for: account).openCodeGoConnected {
                                keyAccount = nil; keyText = ""
                            }
                        }
                    }.disabled(keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || keyConnecting)
                }
                if let error = model.accountRuntime(for: account).openCodeGoError ?? model.accountManagementError {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(20).frame(width: 440)
        }
    }

    private func requestSignIn(_ account: AccountReference) {
        if account.platform == .openCodeGo {
            keyText = ""; keyConnecting = false; keyAccount = account
        } else {
            Task { await model.signInAccount(id: account.id) }
        }
    }

    private func accountRow(_ account: AccountReference) -> some View {
        let selected = model.visibleAccounts.contains(account)
        let snapshot = model.accountRuntime(for: account).snapshot(for: account.platform)
        let runtime = model.accountRuntime(for: account)
        let recovery = runtime.recoveryPresentation()
        let localAnalysis = account.platform == .openCodeGo
        let index = model.visibleAccounts.firstIndex(of: account) ?? -1
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { model.visibleAccounts.contains(account) }, set: { model.setAccountVisible(account, visible: $0) })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.accountLabel(account)).fontWeight(.medium).lineLimit(1).help(model.accountLabel(account))
                        Text(account.platform.title + " · " + model.accountConnectionLabel(account))
                            .font(.footnote).foregroundStyle(.secondary)
                        Text(model.accountPurpose(account, settings: settings))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.toggleStyle(SettingsToggleStyle()).disabled(!selected && model.visibleAccounts.count >= 4)
                Spacer(minLength: 0)
                if selected {
                    Button { model.moveAccount(account, by: -1) } label: { Image(systemName: "arrow.up").frame(minWidth: 24, minHeight: 24) }
                        .disabled(index == 0).help("上移 \(model.accountLabel(account))")
                    Button { model.moveAccount(account, by: 1) } label: { Image(systemName: "arrow.down").frame(minWidth: 24, minHeight: 24) }
                        .disabled(index == model.visibleAccounts.count - 1).help("下移 \(model.accountLabel(account))")
                }
                Button(managing == account ? "收起" : "管理") { managing = managing == account ? nil : account }

            }
            if managing == account {
                TextField("显示名称", text: Binding(get: { model.accountLabel(account) }, set: {
                    model.renameAccount(account.profileID, platform: account.platform, label: $0)
                })).textFieldStyle(.roundedBorder)
                HStack {
                    Button("额度变化") { UsageAnalysisWindowController.shared.show(model:model,account:account,section:.quotaChanges) }
                    Button("用量分析") { UsageAnalysisWindowController.shared.show(model:model,account:account) }
                    switch recovery.action {
                    case .signIn:
                        Button(account.platform == .openCodeGo ? "输入 API Key" : (snapshot.isConnected ? "重新登录" : "登录")) { requestSignIn(account) }
                            .disabled(!recovery.canPerformAction)
                    case .retry:
                        Button("重试更新") { Task { await model.refreshAccount(id: account.id) } }
                            .disabled(!recovery.canPerformAction)
                    case .officialPage: EmptyView()
                    case .wait: Button("等待冷却 / 更新") {}.disabled(true)
                    }
                }.disabled(snapshot.isSigningIn)
                if account.platform == .antigravity {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("额度来源：" + runtime.antigravitySource.title)
                        HStack {
                            if runtime.antigravitySource == .cloud {
                                Button("重新登录 Google") { Task { await runtime.connectAntigravity(source: .cloud) } }
                                Button("改用本机读取") {
                                    runtime.setAntigravitySource(.local)
                                    Task { await runtime.refresh(.antigravity) }
                                }
                            } else {
                                Button("改用 Google 云端") { Task { await runtime.connectAntigravity(source: .cloud) } }
                            }
                        }.disabled(runtime.antigravitySigningIn || runtime.antigravityLoading)
                    }.font(.footnote)
                }
                HStack {
                    Button("官方用量页") { openURL(account.platform.officialUsageURL) }
                    if recovery.action != .signIn {
                        Button(account.platform == .openCodeGo ? "输入 API Key" : "重新登录") { requestSignIn(account) }
                            .disabled(snapshot.isSigningIn || runtime.isRefreshing || !runtime.networkAvailable)
                    }
                }
                if let explanation = recovery.explanation {
                    Text(explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("额度：" + runtime.freshness(for: account.platform).label).foregroundStyle(.secondary)
                Text((localAnalysis ? "本机用量：" : "官方日统计：")
                    + runtime.analysis.freshness(connected: localAnalysis || snapshot.isConnected,
                                                 networkAvailable: localAnalysis || runtime.networkAvailable).label)
                    .foregroundStyle(.secondary)
                if localAnalysis {
                    Text("此 Mac 的 Go 记录按设备汇总，所有 OpenCode 账号共用此统计。")
                        .foregroundStyle(.secondary)
                }
                if let failure = runtime.analysis.refreshFailure {
                    Text(localAnalysis
                         ? (runtime.analysis.error ?? "本机用量读取失败，请稍后刷新")
                         : (failure == .authorization
                            ? "日统计接口未接受当前授权；额度连接状态保持独立，可先查看官方页面。"
                            : "日统计接口：" + failure.message(for: account.platform))).foregroundStyle(.orange)
                }
                Button("移除", role: .destructive) { removal = account; confirmsRemoval = true }
                    .disabled(snapshot.isSigningIn)
                    .help("移除「\(model.accountLabel(account))」")
                    .accessibilityLabel("移除「\(model.accountLabel(account))」")
                if let schedule = model.accountRuntime(for: account).refreshPolicy.explanation { Text(schedule).font(.footnote).foregroundStyle(.secondary) }
                if let error = snapshot.error { Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            }
        }.padding(11).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
    }
}
