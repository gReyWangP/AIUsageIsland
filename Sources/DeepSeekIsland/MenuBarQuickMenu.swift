import AppKit

extension MenuBarStatusController {
    var displayedMetric: UsageMetric { settings.menuBarAutoFocusEnabled ? autoDisplayedMetric ?? settings.menuBarMetric : settings.menuBarMetric }

    func supportsMetric(_ metric: UsageMetric) -> Bool {
        guard model.platformAccounts.enabled.contains(metric.platform) else { return false }
        return source(for: metric.platform).capabilities.metric(metric).canSelect
    }
    var canRefreshDisplayed: Bool { canRefresh(displayedMetric.platform) }
    func canRefresh(_ platform: UsagePlatform) -> Bool {
        guard model.platformAccounts.enabled.contains(platform), model.networkAvailable, !model.isSleeping else { return false }
        let source = self.source(for: platform)
        switch platform {
        case .deepSeek: return source.accountConnected && !source.isLoading
        case .zhipu: return source.zhipuConnected && !source.zhipuLoading
        case .chatGPT: return source.chatGPTConnected && !source.chatGPTLoading
        }
    }
    func selectMetric(_ metric: UsageMetric) {
        guard supportsMetric(metric) else { return }
        settings.menuBarAutoFocusEnabled = false
        settings.menuBarMetric = metric
        update()
    }
    func refreshDisplayedPlatform() {
        refreshPlatform(displayedMetric.platform)
    }
    func refreshPlatform(_ platform: UsagePlatform) {
        guard canRefresh(platform) else { return }
        let source = self.source(for: platform)
        if source.account == model.activeAccountReference(for: platform), let onRefresh { onRefresh(platform) }
        else { Task { await source.refresh(platform) } }
    }
    func makeQuickMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: "当前：" + title(for: displayedMetric), action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        for platform in settings.orderedPlatforms where model.platformAccounts.enabled.contains(platform) {
            for metric in UsageMetric.allCases where metric.platform == platform {
                let data = self.data(for: metric)
                let suffix: String
                if case .unavailable(let reason) = data { suffix = " — " + reason } else { suffix = "" }
                let item = NSMenuItem(title: title(for: metric) + suffix, action: #selector(chooseQuickMetric(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = metric.rawValue
                item.state = displayedMetric == metric ? .on : .off
                item.isEnabled = supportsMetric(metric)
                menu.addItem(item)
            }
        }
        if model.savedAccounts.count > 1 {
            menu.addItem(.separator())
            let accounts = NSMenu(title: "选择账号")
            accounts.autoenablesItems = false
            for account in model.orderedSavedAccounts {
                let source = model.accountRuntime(for: account)
                let connected = source.hasConnectedAccount(for: account.platform)
                let ready = connected && source.hasLoadedAccountData(for: account.platform)
                let title = model.accountLabel(account) + " · " + account.platform.title
                    + (ready ? "" : connected ? " — 等待首次更新" : " — 未完成登录")
                let item = NSMenuItem(title: title, action: #selector(chooseQuickAccount(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = account
                item.isEnabled = ready
                item.state = displayedMetric.platform == account.platform && displayedAccount(for: account.platform) == account ? .on : .off
                accounts.addItem(item)
            }
            let item = NSMenuItem(title: "选择账号", action: nil, keyEquivalent: "")
            item.submenu = accounts; menu.addItem(item)
        }
        menu.addItem(.separator())
        let automatic = NSMenuItem(title: "自动关注紧张的额度", action: #selector(toggleQuickAutoFocus), keyEquivalent: "")
        automatic.target = self; automatic.state = settings.menuBarAutoFocusEnabled ? .on : .off
        menu.addItem(automatic)
        let refresh = NSMenuItem(title: "刷新当前账号", action: #selector(refreshQuickMetric(_:)), keyEquivalent: "")
        refresh.target = self; refresh.isEnabled = canRefreshDisplayed
        refresh.representedObject = displayedMetric.platform
        menu.addItem(refresh)
        let open = NSMenuItem(title: "打开详情", action: #selector(openQuickDetails), keyEquivalent: "")
        open.target = self; menu.addItem(open)
        return menu
    }
    @objc private func chooseQuickAccount(_ item: NSMenuItem) {
        guard let account = item.representedObject as? AccountReference,
              model.accountRuntime(for: account).hasConnectedAccount(for: account.platform),
              model.accountRuntime(for: account).hasLoadedAccountData(for: account.platform) else { return }
        settings.menuBarAccount = account
        let metric = displayedMetric.platform == account.platform ? displayedMetric : UsageMetric.defaultMetric(for: account.platform)
        selectMetric(metric)
    }
    @objc private func chooseQuickMetric(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let metric = UsageMetric(rawValue: raw) else { return }
        selectMetric(metric)
    }
    @objc private func toggleQuickAutoFocus() { settings.menuBarAutoFocusEnabled.toggle(); update() }
    @objc private func refreshQuickMetric(_ item: NSMenuItem) {
        guard let platform = item.representedObject as? UsagePlatform else { return }
        refreshPlatform(platform)
    }
    @objc private func openQuickDetails() { onOpen() }
}
