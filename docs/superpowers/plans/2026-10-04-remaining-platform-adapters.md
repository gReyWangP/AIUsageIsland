# DeepSeek 与智谱适配器改造

用户明确要求停止当前会话测试、回到适配与升级改造。本轮不新增或运行测试，不启动 UI 或发布；仅进行源码与调用关系检查。上轮测试数字不作为本轮通过证据。

## 设计
- DeepSeekServing 定义余额、资料和用量读取，可由 IslandModel 注入。DeepSeekUsageAdapter 先获取余额并在当前账号仍有效时提交，再获取用量；辅助用量授权失败不清除可用余额。取消与迟到结果不覆盖当前状态。
- ZhipuUsageAdapter 封装 ZhipuWebSession 的回调、20 秒刷新超时与暂停。取消导航不误报失败；运行时保留身份归属确认。关闭回调同样验证适配器身份。
- UsageRefreshFailure 提供共享的取消/网络错误映射；平台适配器负责各平台错误枚举的转换。保留界面字符串兼容入口，不改持久化格式。
- 已写入的 ApplicationInstanceLock 启动保护保留；它不能强制未升级旧版遵守锁。

## 实施记录
- [x] DeepSeek 接口、适配器与运行时接入。
- [x] 智谱适配器与结构化失败接入。
- [x] 源码核对与文档更新（不进行编译、测试或打包）。

基线 /tmp/aiusage-platform-adapters-baseline-20261004。无 Git，未提交。
