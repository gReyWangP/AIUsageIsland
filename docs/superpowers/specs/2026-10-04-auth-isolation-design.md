# 三平台登录会话隔离

DeepSeek/ChatGPT 使用 ASWebAuthenticationSession，每次创建新实例，start 前设置 prefersEphemeralWebBrowserSession=true。通过现有 loopback HTTP 接收 state/PKCE 回调；session 的 callbackURLScheme 为 nil，不改变第三方注册的 redirect URI。浏览器取消/失败关闭本次 loopback；完成/失败/超时清理本次浏览器，不影响后续会话。

Safari 尊重临时请求。其他浏览器若声明支持系统认证，则必须明确声明 EphemeralBrowserSessionIsSupported，否则拒绝启动并提示使用支持隔离的默认浏览器；未声明认证支持时系统按 Apple 文档回退 Safari。无法识别浏览器时拒绝，不悄悄打开普通浏览器。该方案依赖浏览器兑现公开声明，真实网页登录需人工验收。

智谱所有账号，包括 legacy，强制 UUID 对应 WKWebsiteDataStore；不再允许 nil/default fallback。保留新账号原 UUID，legacy 映射到固定有效 v4 UUID（原账号 ID 是不被 WebKit 接受的哨兵），不迁移共享默认数据以免归属错误，旧账号可能需一次重新登录。账号移除只清理所属专用数据空间。

本地 token 文件、账号身份重复检测和请求版本绑定保持。三平台都覆盖，OAuth 不换成嵌入 WebView，避免第三方身份提供商拒绝嵌入式登录。
