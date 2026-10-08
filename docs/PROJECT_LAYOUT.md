# 项目目录与开发入口

项目位置：`/Users/greys/SwiftProjects/AIUsageIsland`。
`SwiftProjects` 与 `/Users/greys/IdeaProjects` 同级，用于存放 Swift 项目。

本项目是标准 Swift Package，支持 macOS 14 及以上，使用 Swift 6。
产品名称为 AI Usage Island，Swift 包名、可执行文件及应用包名使用 AIUsageIsland；源码 target 和数据目录沿用 DeepSeekIsland，以兼容已有账号。

## 目录

```text
AIUsageIsland/
├── Package.swift          # Swift Package 定义，Xcode 打开入口
├── Sources/DeepSeekIsland/ # Swift / SwiftUI / AppKit 源码
│   └── Resources/         # 界面内 Logo 等 SwiftPM 资源
├── Tests/DeepSeekIslandTests/ # 单元测试和原生界面回归
├── Resources/             # 应用图标、打包用资源
├── Info.plist             # 应用标识、版本和权限文案
├── scripts/               # 构建、图标生成及编辑器入口
├── docs/                  # 设计、验证与目录说明
├── releases/              # 按版本保存发布快照
│   └── 1.17.0/            # 安装包、源码快照、界面预览
├── dist/                  # 本机构建的 .app（构建后生成）
└── .build/                # SwiftPM 构建缓存（自动生成）
```

## 在编辑器中打开

- Xcode：打开根目录的 `Package.swift`，或执行 `bash scripts/open-in-xcode.sh`。选择 DeepSeekIsland scheme 浏览、构建和调试。
- VS Code / Cursor：打开整个 `AIUsageIsland` 目录，使用编辑器的 Swift 支持进行代码导航。
- `main.swift` 为启动入口；`IslandModel.swift` 管理账号目录和应用编排。
- `IsolatedOAuthBrowser.swift` 管理系统临时授权会话与浏览器能力检查；两个 OAuth flow 保留 PKCE/本机回调，并按尝试清理授权会话。智谱网页空间由账号标识映射，清理与加载串行。
- `DeepSeekUsageAdapter.swift` 分阶段读取余额与用量，`DeepSeekServing` 支持网络依赖注入；`ZhipuUsageAdapter.swift` 管理网页结果与刷新超时，运行实例负责账号身份核验。
- `ApplicationInstanceLock.swift` 在启动时为凭据目录持有进程级互斥锁；未升级旧版不遵守新锁。
- `ChatGPTUsageAdapter.swift` 负责额度读取、单次令牌续期与保存顺序；`UsageRefreshFailure.swift` 定义安全错误分类，账号生命周期与界面状态仍由 `AccountRuntime` 管理。
- `UsageMetric.swift`、`UsageReading.swift` 定义业务指标与读数；`QuotaWindowState.swift` 统一有限/无限窗口及数值校验。提醒与展示共同读取业务结果。
- `AccountRuntime.swift` 持有固定账号的数据、认证和刷新；`AccountRuntime+Snapshot.swift` 转换展示快照。
- `IslandModel+Accounts.swift` 管理显示选择及运行实例集合；`IslandModel+Compatibility.swift` 是现有平台式调用的过渡代理，不保存另一份数据。
- `DataFreshness.swift` 集中判断三个平台的新鲜度，读取结构化错误并兼容旧提示；DeepSeek 余额与用量分别使用各自成功时间。重置补查和菜单栏本地取值读取对应账号运行实例；后台用途变化由主模型观察设置后统一协调。
- 视图文件位于同一 Sources 目录；测试入口在 Tests。

## 构建与验证

在项目根目录执行：

```bash
swift build
swift test
bash scripts/build-app.sh
```

最后一个命令输出 `dist/AIUsageIsland.app`，包含 Info.plist、图标、SwiftPM 资源和临时签名。
直接运行 SwiftPM 可执行文件不等同于完整 macOS 应用包。
调试或运行新版前先退出旧版本，避免两个实例同时刷新同一账号授权。

## 发布压缩包

每个版本使用独立子目录，例如 `releases/1.17.0/`：

- `DeepSeekIsland-1.17.0-app.zip`：分发安装包。
- `DeepSeekIsland-1.17.0-source.zip`：发布时的源码快照，不作为日常编辑目录。
- `reminder-preview.png`、`settings-preview.png`：该版本的界面预览。

日常修改项目根目录里的源码。下一次发布创建新的版本目录，保留旧快照。
压缩源码时排除 `.build`、`.swiftpm`、`dist`、`releases` 和 `.git`，避免缓存、应用包和历史 ZIP 被再次套入源码包。
