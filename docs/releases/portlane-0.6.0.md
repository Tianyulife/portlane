# Portlane 0.6.0 · Steam 生命周期与插帧改进

Portlane 0.6.0 是 macOS Windows Steam 兼容性研究预览版，合入上游近期改进，并保留 Portlane 的界面、Steam 启动衔接、单游戏配置和空间音频运行时。

## 本版更新

- Steam 云存档在后台维护待上传记录，正确解析 CRLF 和尚未写完的日志；退出或切换运行环境前检查游戏、下载与待上传状态。取消退出后继续监测，必要时可仅退出 Portlane、保留 Steam。云存档状态请在官方 Steam 中查看。
- 共享 Steam 会话取消对 CLR 的默认禁用，移除《黑神话：悟空》的自动 CLR 特例；保留用户明确设置的 DLL 覆盖。
- Wine 字体与显示准备遇到超时时，清理残留进程并限次重试，留下诊断日志；补齐 NVAPI 文件别名。
- Steam 下载状态改进实际阶段、进度及容量解析，清理过期记录。
- 实验性通用插帧使用显示回调、处理尺寸预算和有界 GPU 队列，改善重复帧、场景变化、窗口可见性及呈现停滞处理。插帧默认关闭，需要 macOS 26 或更高版本。
- 保留 Wine 虚拟桌面开关及分辨率设置，增加已知限制说明：当前 macOS 引擎可能使画面固定在左上角、无法移动；遇到此问题可关闭选项，保存并重启游戏。
- 修复打包本地化检查，保留中英文界面。

## 下载与安装

- `Portlane-0.6.0-macOS-arm64.dmg`：Apple Silicon Mac 应用，要求 macOS 15 或更高版本。退出旧版 Portlane，打开 DMG，将应用拖入 Applications 替换原版本。
- `Portlane-0.6.0-macOS-arm64.dmg.sha256`：在下载目录运行 `shasum -a 256 -c Portlane-0.6.0-macOS-arm64.dmg.sha256` 校验。
- 首次设置继续自动下载 [Wine 11.0.9-services.1 空间音频服务版](https://github.com/Tianyulife/portlane/releases/tag/v0.5.1)。本次没有重建 Wine，已有运行时无需重复安装。

更新后退出并重新打开受管理的 Windows Steam，让新版兼容组件生效。原有 Steam 登录、游戏、存档和 Portlane 配置沿用现有数据目录。Steam、游戏和 Apple GPTK / D3DMetal 单独安装或导入。

## 验证与状态

本地完整检查、Swift 单元测试、Wine 补丁检查、JavaScript 回归、Release 应用与 CLI 构建通过；应用签名、打包本地化、DMG 挂载与资源校验通过。具体计数和制品 SHA-256 见 [验证记录](https://github.com/Tianyulife/portlane/blob/v0.6.0/docs/validation/portlane-upstream-port-20261011.json)。

用户确认《黑神话：悟空》关闭虚拟桌面后正常，开启后仍存在窗口定位问题。云存档跨设备一致性、真实退出/重启保护以及插帧战斗画质、延迟和长时间运行仍待完整实机验收。应用采用 ad-hoc 签名，尚未公证，继续作为 prerelease 发布。

上游来源与取舍见 [移植记录](https://github.com/Tianyulife/portlane/blob/v0.6.0/docs/UPSTREAM_PORT_PLAN.md)。空间音频 Wine 沿用既有补丁和署名；其他第三方来源见 [THIRD_PARTY_NOTICES](https://github.com/Tianyulife/portlane/blob/v0.6.0/THIRD_PARTY_NOTICES.md)。
