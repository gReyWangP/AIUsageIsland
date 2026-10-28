# GitHub 源码与安装包分发

- 源码仓库（公开）：https://github.com/gReyWangP/AIUsageIsland
- 公开分发仓库：https://github.com/gReyWangP/AIUsageIsland-releases
- 当前公开安装包：https://github.com/gReyWangP/AIUsageIsland-releases/releases/tag/v1.19.29

公开仓库只包含 README、发布说明和安装 ZIP 的 SHA256；Release 附件只包含应用安装 ZIP 和 SHA256SUMS，不包含源码快照、开发日志、编译缓存或凭据。

源码开发目录保持原位置，Git 的 origin 指向公开源码仓库。公开分发仓库本地工作目录为 `releases/github-distribution`，由源码仓库的 ignore 规则排除；各版本归档继续保存在 `releases/<版本>/`。

当前包支持 macOS 14+ / Apple Silicon，采用临时签名，未完成 Developer ID 签名公证。公开发布标题和正文以功能与安装说明为主，1.19.29 已设置为最新发布；源码仓库公开，安装包、SHA256SUMS 和 appcast 在公开分发仓库维护。

GitHub CLI 登录凭据保存在系统钥匙串；私钥、环境配置和本地账号数据不提交仓库。本机 HTTPS 推送使用仓库级 HTTP/1.1、较大 POST 缓冲和空 Expect 请求头以兼容当前网络传输；不修改其他仓库的配置。
