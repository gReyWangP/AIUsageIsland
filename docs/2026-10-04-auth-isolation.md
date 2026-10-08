# 三平台登录会话隔离

## 改动

DeepSeek 与 ChatGPT 不再使用 NSWorkspace.open 打开普通登录标签页。每次创建新的 ASWebAuthenticationSession，启动前请求临时会话；现有 PKCE、state、本机回调地址与 token 存储保留。登录成功、失败、超时或取消时释放本次浏览器；迟到回调不会关闭下一次会话。用户在 token 交换期间关闭授权窗口，也不再返回可保存凭据。

浏览器能力检查：Safari 允许；默认浏览器不支持系统认证时按系统规则使用 Safari；支持系统认证却未声明临时会话支持时拒绝启动。启动失败或无法识别浏览器时提示，不回退普通浏览器。系统会话依赖第三方浏览器兑现其能力声明，不能把设置一个布尔值等同于已实测所有浏览器。

智谱改为必填账号标识的专用 WebKit 数据空间，新账号沿用已有 UUID。legacy 哨兵 UUID 不被 WebKit 接受，映射至稳定有效的专用 UUID。移除只清理该账号空间（包含第三方登录 Cookie），重新加载等待清理完成。

## 升级影响

DeepSeek、ChatGPT 已保存 token、刷新令牌及账号设置不迁移。智谱曾使用默认网页空间的旧账号需要重新登录一次；不复制可能归属不明的默认 Cookie/网页存储，也不修改默认浏览器中的登录状态。

## 验证

基线 371 项测试，1 项联网测试跳过，0 失败。新增 11 项隔离测试；59 项相关测试通过。测试覆盖临时开关先于启动、浏览器能力策略、不支持时不创建会话、旧 completion 隔离、启动失败清理、两平台真实本机 HTTP 回调、取消/交换时关闭、智谱实际 WebKit Cookie 隔离与清理。

完整 `swift test`：382 项，1 项显式联网测试跳过，0 失败。独立只读审阅未发现严重或重要问题；既有 loopback 请求行分片处理仍是后续改进点。

系统会话在自动化测试中使用 fake，未启动真实网站登录。仍需在支持隔离的浏览器中验收：预先登录账号 A，应用新增账号 B 后确认未自动授权 A；连续新增、取消重试；智谱两账号重启恢复、移除一个保留另一个。平台/账号绑定仍由原有身份校验保护。

Release 打包通过，图标/资源与 ad-hoc 签名校验通过。产物 `/tmp/aiusage-auth-isolation-20261004/AIUsageIsland.app`，未安装或发布。

## 技术依据

- [Apple：临时授权会话](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession/prefersephemeralwebbrowsersession)：Safari 尊重请求，其他浏览器行为取决于实现。
- [Apple：浏览器临时会话能力声明](https://developer.apple.com/documentation/bundleresources/information-property-list/aswebauthenticationsessionwebbrowsersupportcapabilities/ephemeralbrowsersessionissupported)。
- [Apple：ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)：不支持系统认证的默认浏览器由 Safari 接管。

当前无 Git，本轮源码快照 `/tmp/aiusage-auth-isolation-baseline-20261004`。

## 后续原生观察与停止验证（2026-10-04）

停止测试前，用临时本机页面及真实系统授权会话观察到：Chrome 普通窗口 Cookie 未进入第一次临时会话，第一次临时会话 Cookie 未进入第二次；两个临时会话各自可以读到自身设置的 Cookie。该结果只覆盖这台机器当时的 Chrome 环境，不代表所有浏览器和平台完整授权流程。

真实 DeepSeek 页面显示新的手机号／验证码登录入口，关闭后返回取消提示；ChatGPT 显示新的邮箱及第三方登录入口。没有输入真实账号凭据，未完成账号 A/B 授权身份对比，也未确认 ChatGPT 取消重试全过程。临时 Cookie 已清理，本机探针和服务已停止。

用户随后要求本会话不再测试。新的平台适配器与单实例保护未重新编译、打包，前文测试数字和 release 产物仅对应此前的登录隔离版本。
