# 应用更新发布

应用使用 Sparkle 2.9.6。自动检查默认关闭，用户选择由 Sparkle 保存；下载和安装使用标准确认界面。首次接入版本 1.19.15 需要手动安装一次，之后可在设置 → 通用与支持 → 软件更新中检查、下载和安装。

源码仓库为公开 `gReyWangP/AIUsageIsland`；安装包、SHA256SUMS 和 appcast 在公开 `gReyWangP/AIUsageIsland-releases` 分发。Feed 地址固定为 https://raw.githubusercontent.com/gReyWangP/AIUsageIsland-releases/main/appcast.xml。

## 签名工具与密钥

从 Sparkle 官方 2.9.6 发布获取 `Sparkle-2.9.6.tar.xz` 并解压；SwiftPM 框架同时固定为 2.9.6，Package.resolved 必须提交。

首次运行官方 `bin/generate_keys --account AIUsageIsland`，私钥写入登录钥匙串。后续通过 `bin/generate_keys --account AIUsageIsland -p` 读取公钥；必须与应用 Info.plist 的 SUPublicEDKey 一致。不要重新生成或更换公钥：已有客户端信任这个固定公钥。私钥不要写入仓库、环境日志或发布资产；换机器前须通过钥匙串或官方工具妥善备份并在新机器恢复，备份仅放个人安全存储。

Sparkle 更新包签名与 Apple 应用签名是两件事。本机当前没有 Developer ID，构建包为临时签名，未完成 Apple 公证。正式公证模式仍需 SIGNING_IDENTITY 与 NOTARY_KEYCHAIN_PROFILE，不会自动回退。

## 每次发布

1. 增加 Info.plist 的 CFBundleVersion（必须比历史发布大），同步 CFBundleShortVersionString。运行完整 `swift test` 与三个 `Tests/BuildScripts/check_*.py` 检查。
2. 执行 `scripts/build-app.sh releases/1.19.15`（以后替换版本目录）。正式签名使用 `--mode release`。脚本嵌入完整框架、辅助进程及许可证，并校验嵌套签名和运行路径；失败保留旧包。
3. 执行 `ditto -c -k --keepParent releases/1.19.15/AIUsageIsland.app releases/1.19.15/AIUsageIsland-1.19.15-build64-arm64.zip`。压缩完成后不能再修改归档；签名和长度针对这个文件。
4. 写功能说明文件，然后执行：

   ```sh
   python3 scripts/generate-update-feed.py \
     --archive releases/1.19.15/AIUsageIsland-1.19.15-build64-arm64.zip \
     --appcast releases/github-distribution/appcast.xml \
     --sign-tool /tmp/aiusage-sparkle-tools/bin/sign_update \
     --notes releases/1.19.15/RELEASE_NOTES.md
   ```

   工具路径应指向实际解压的官方版本。生成器读取 ZIP 中的应用版本、构建号、公钥和系统版本，核对钥匙串公钥，签名并验证，成功后才原子写入 XML。失败保留旧清单；旧版本条目继续保留。
5. 用 `shasum -a 256` 生成 SHA256SUMS。先创建 GitHub draft release，上传 ZIP 和校验文件，核对资产名称、字节长度与摘要。Release 标题和说明写功能项、使用方式及版本变化，不写测试内容。
6. 发布 Release 后再提交并推送公开仓库的 appcast.xml。验证公开 HTTPS feed 与已上传资产的版本、长度、签名一致。源代码单独提交推送；源码快照和验证日志只保留本地，不上传公开仓库。

## 隔离验收

使用唯一 Bundle ID 的临时宿主、无账号的可执行文件、本机 HTTP feed 和官方 sparkle-cli 源码构建的工具，验证 Ed25519 签名归档下载及旧/新版本替换。再破坏签名并确认拒绝；过程不能运行或覆盖用户正在使用的应用。生产 feed 必须使用 HTTPS。
