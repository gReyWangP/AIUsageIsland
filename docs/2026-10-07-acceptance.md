# 1.19.5 使用验收记录（2026-10-07）

## 已完成

- 用户确认 1.19.5 的悬浮到详情、打开分析、7/30 天切换已经流畅。
- 当前运行版本由只读进程采样确认是 1.19.5（build 54）；没有启动第二个生产实例。
- 三秒空闲采样的主线程大部分在系统消息等待，没有观察到空闲期间持续执行统计计算。此结果不代表所有交互或长时间运行已完成性能验证。
- 只读读取两份日统计缓存，未读取登录授权、Cookie、账号资料。ChatGPT 44 个返回日期、DeepSeek 31 个日期，检查未发现重复日期、负数或分类 Token 与总量不一致。智谱没有可核验的日统计缓存。
- 增加 RecordedUsageAcceptanceTests，在显式传入仅数值日统计副本时运行，使用独立临时账号目录和离线模型。两份真实缓存的 100 次周期/概览访问约 2–3 毫秒；原生布局与位图绘制约 101–151 毫秒，其中包含 50 毫秒等待。这是隔离测试耗时，不是用户点击的端到端延迟。
- 专项测试通过。完整测试日志：/tmp/aiusage-acceptance-full.log。

## 当前通知问题

用户反馈通知会进入通知中心，但没有在桌面弹出。

代码检查：SystemUsageNotifications 请求 alert 授权；willPresent 在允许提醒时返回 banner/list；额度通知没有指定声音。权限文案把 authorized、provisional、ephemeral 合并为“系统通知已允许”，无法判断桌面提醒样式和横幅是否实际开启。

界面自动化连接两次超时，不能读取当前系统设置。旧通知偏好文件未找到此应用条目，不能据此判定权限拒绝，也没有修改系统偏好。已打开系统通知设置以便用户核对。

需检查“系统设置 → 通知 → AIUsageIsland”的允许通知、桌面展示/横幅或提醒样式，以及专注模式和镜像/共享屏幕的通知限制。Apple 文档说明临时授权可静默投递；当前应用没有主动请求 provisional，因此不能认定本机处于该状态。

## 仍待验证

- 对照官方页面确认统计与日界线；当前只验证已保存响应的内部一致性，不代表来源数据完整性已验收。
- 智谱真实 Token 历史、套餐差异以及完整多账号登录流程。
- 通知真实横幅显示、系统登录项、实体多屏/合盖/唤醒。
- 正式签名、公证与自动更新仍暂缓。

### 通知横幅排查（1.19.6）

用户截图确认允许通知、桌面、通知中心和锁屏均开启，样式为临时；不能据此认定授权失败。添加“通知检查与测试”入口：5 秒延迟、独立测试类别、无声音、不修改额度提醒开关。记录授权状态、alertSetting、alertStyle、通知中心设置、声音设置、应用活动状态、代理是否存在、提交结果、前台 banner/list 决策、8 秒后测试通知中心回查。日志保留最近 200 条，仅固定事件及系统数字，不含账号、凭据、URL 或通知正文。

待用户验证：退出旧版后打开 1.19.6；第一次保持设置前台，第二次点击后切换其他应用，各等待约 8 秒并记录是否出现横幅、是否进入通知中心。复制通知日志分析。应用后台没有 willPresent 回调属正常；通知中心出现并不能证明横幅显示。专注模式、屏幕共享或 macOS 内部抑制原因没有通过日志直接确认。

### 13:27 通知测试的系统侧证据

用户确认只有通知中心记录，无桌面横幅。应用日志：13:27:29 submitted，13:27:34 foregroundBanner，13:27:37 delivered。同期 usernoted/NotificationCenter 统一日志显示：DND interruptionSuppression=none、activeModeUUID=null；系统接收 banner/list 展示请求，但 canDisplayWhileCenterIsClosed=false。抑制上下文为 <private>，不能据此断言最终具体原因。

经原生系统设置 AX 读取：应用通知允许，桌面/通知中心/锁屏均勾选，临时样式；全局“当镜像或共享屏幕时”为“关闭通知”。这是下一步优先验证项。未修改用户全局设置，尚未确认测试时是否实际处于共享/录屏状态。建议用户临时改为“允许通知”或停止共享后再次测试；如仍不弹，再检查系统展示状态，避免将系统展示问题误判为应用授权失败。

### 专注模式方向的独立排查

13:27 和 13:35 两次测试，DND 行为解析均为 interruptionSuppression=none、resolutionReason=disabled、activeModeUUID=null；没有证据支持这两次横幅被专注模式抑制。原生系统设置显示跨设备共享关闭，勿扰模式智能启用关闭；勿扰模式允许 App 列表为空仅说明该模式启用后的策略，不代表当时正在启用。未修改任何专注或通知设置。

两次应用日志都含 foregroundBanner，因此仍缺后台路径对照。尝试通过 CUA 获取运行中的应用以点击测试按钮，应用 UI 读取超时，未触发新通知。下一步需用户点击测试后立即切换到其他应用，避免自动将前台路径的结果外推到后台。镜像尚未确认为原因，不再据此认定根因。

### 设置热区修正（1.19.7）

通知排查按用户要求暂时停止。检查了设置页全部 DisclosureGroup、Toggle、Button 和选择控件。采用统一的 SettingsDisclosureGroupStyle：只在折叠标题放置一个完整宽度按钮，展开后的内容不附加父层点击手势，避免输入框或保存按钮触发收起。SettingsToggleStyle 以单个整行按钮修改绑定，原生指示器不独立响应，因此点击指示器、文字及行内空白只切换一次；继承禁用状态并提供开启/关闭的辅助功能值。覆盖所有设置复选框及状态栏 switch。卡片描边关闭命中，账号上移/下移、清除快捷键、引导按钮扩大热区。侧栏/屏幕/布局按钮已有 contentShape，无需重复添加父层手势。原生 Picker、DatePicker、TextField 和标准按钮保留各自控件边界，未将包含多个操作的整张卡片设为点击区。

### Codex 通知对照（用户新增线索）

读取两小时系统通知日志并仅提取两个应用的展示状态：AIUsageIsland 11:48:55 canDisplayWhileCenterIsClosed=true；Codex 12:10/12:14/13:45:49 为 true。Codex 13:38:58 为 false 且 hasSound=true/isMuted=true，同期有明确日志“muted by display state (displayShared)”。系统于 13:37:46 进入共享状态，13:39:30 退出；doNotDisturbEnabled 始终显示 false。因此不能把 Codex 一直正常作为全局状态永远正常的证明。

另一方面，AIUsageIsland 13:41:36 的测试在已退出上述共享状态后仍为 false、isMuted=false。三次失败测试均含前台 deferred 展示记录，选项 list/banner；Codex 成功和 AIUsageIsland 11:48 成功走的是系统直接展示记录，选项 badge/sound/alert。路径差异是待验证假设，不能把系统后台默认 alert 选项当成 Codex 前台回调代码，也不能凭日志断言 list/banner 使用错误。Apple 文档及当前 SDK 推荐 list/banner 替代已经弃用的 alert；若验证兼容性，应仅做隔离对照实验。

声音差异已由应用代码确认：授权仅申请 alert，普通提醒和测试内容未设置 sound，前台展示未请求 sound。没有声音是现有实现的明确行为，和横幅抑制应分别处理。没有读取 Codex 用户配置、会话或凭据，未变更两款应用的通知设置。

### 联合采集结果及隔离兼容探针（1.19.8）

已执行临时 3 分钟联合日志观察，仅输出两款应用的状态而不保存通知正文。13:55:11 Codex 的 focusDecision=notSuppressed、desktopAllowed=true、muted=false；13:56:12 AIUsageIsland 的 focusDecision=notSuppressed、foregroundPresentation、desktopAllowed=false、muted=false。最新测试仍含前台回调，不能标记为已完成后台对照。原始 URL 及账号信息未进入整理结果。

为验证前台选项兼容性，保留原有测试，并添加隔离兼容测试类别：只给该类别的前台返回值加入旧 alert 位，同时保留 banner/list。所有自动提醒继续原有策略。提供严格解析的本机诊断 URL：scheme/host/path/query 均受限，必须预先授权，不自动申请权限；与手动测试共用互斥和 8 秒查询。后续打开新版后可以通过本机 URL 发起标准与兼容测试，避免依赖已超时的应用 AX 控制。尚需在用户运行的正式 app 中实测，不能声称已修复横幅。

### 1.19.8 本机自动对照结果（14:02—14:03）

确认运行进程为 releases/1.19.8/AIUsageIsland.app（PID 43919）。通过本机已授权 URL 入口依次触发标准与兼容测试，间隔超过测试互斥时间。14:02:58 标准前台回调返回 24（banner/list），系统 canDisplayWhileCenterIsClosed=false。14:03:17 兼容前台回调返回 28（alert/banner/list），系统 canDisplayWhileCenterIsClosed=true。两次提交均成功，均在前台回调后进入通知中心，系统权限及应用活动状态相同；两条测试内容均无声音。这两次前台展示的系统允许标志不同，尚不足以认定兼容选项能稳定恢复横幅。已请求用户确认兼容横幅实际出现；系统允许显示不等同于用户已看到。

### 兼容复测与真正后台测试（14:04—14:08）

用户确认兼容测试没有弹出。14:04:42 再次兼容回调返回 28，但系统 canDisplayWhileCenterIsClosed=false、isMuted=false。兼容 alert 位未稳定恢复显示，因此不提升到自动提醒，不认定修复。

让系统设置处于前台，并通过 open -g 触发标准诊断，14:08:27 提交时 appActive=0，回查仍为 0，无 foregroundBanner 回调，首次确认走真正后台路径。14:08:32 系统 DND 决策明确为 interruptionSuppression=silence、resolutionReason=display shared，NotificationCenter 记录 muted by display state (displayShared)、isMuted=true。14:05:42 系统曾记录 isScreenShared=1、isScreenMirrored=0。本次失败存在明确共享抑制，但不能外推为全部历史失败的原因；此前多次前台失败 isMuted=false。屏幕共享状态的来源尚未确认，可能包含采集工具，不能仅凭状态认定具体应用。未改动全局通知或专注设置。

### 用户允许共享期间通知后的后台对照（14:13）

用户确认已将镜像或共享时通知设为允许。保持其他应用前台，通过 open -g 发送标准测试：14:13:20 提交，appActive=0，14:13:29 回查 delivered，仍为后台，无前台回调。14:13:25 系统 interruptionSuppression=none、resolutionReason=disabled、activeModeUUID=null、canDisplayWhileCenterIsClosed=true、isMuted=false。与 14:08 后台测试相比，共享抑制已消失，未修改应用代码或增加兼容 alert 位。尚待用户确认实际横幅，不能仅凭系统标志宣称显示成功。

用户确认 14:13 测试没有看到横幅。追加检查 NotificationCenter 展示日志：14:13:25.868519 Setting visible banner，随后 Found existing banner，显示目标为主屏幕 2560×1440；14:13:30.869766 Clearing banner after expiration。系统确实建立了横幅展示状态并在约 5 秒后清除，仍不能证明用户屏幕实际绘制可见。只读 NSScreen 检查当前只有一个 2560×1440 屏幕，暂无其他屏幕投递证据。下一步可将此应用临时横幅样式改为持续，区分短暂消失与实际隐藏，不应继续修改前台兼容选项作为未经验证的修复。

### 持续样式实测成功（14:15）

用户已将 AIUsageIsland 样式改为持续，并提供 Codex 临时横幅正常显示的截图。14:15:50 后台标准测试，settings=[2,2,2,2,0,0,1]；14:15:55 系统按 alert 展示，canDisplayWhileCenterIsClosed=true、isMuted=false，主屏幕 2560×1440；通知中心回查成功。用户随后明确确认“有了”，首次完成本轮实际桌面展示验收。本次仍采用标准后台通知，无兼容 alert 前台回调，无声音，无新增业务代码。

结论：共享期间允许通知且应用采用持续样式的组合已经用户验证可用；授权、后台提交、桌面展示链路正常。暂时不能确定临时样式不可见的具体原因，不能宣称全局临时样式失效或兼容探针修复成功。保持用户当前设置，不自动修改系统偏好；若继续排查临时样式，需在其他条件不变且关闭旧持续通知后进行单变量复测。

### 按用户要求结束通知实验（1.19.9）

移除通知测试卡片、标准/兼容测试类别、本机 notification-test URL 路由、测试专用控制器状态/后端协议、诊断日志写入和测试专用单元测试。恢复正常提醒前台回调的 banner/list 标准选项；保留正常额度/官方动态/预约提醒及系统授权、桌面提醒和横幅样式说明。未改变用户系统通知设置。源码扫描无实验标识残留。完整测试 418 项，1 项跳过，0 失败；日志 /tmp/aiusage-remove-probes-full.log。
