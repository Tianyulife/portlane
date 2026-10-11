# Portlane 上游改动移植计划

记录日期：2026-10-11（北京时间）。状态：六项代码移植已完成，纳入 Portlane 0.6.0 预览版；真实游戏与跨设备验收待完成。

## 当前实现

- 云日志解析及持久待上传记录、退出／relay 重启保护已适配；等待结束后再次检查游戏和下载。退出确认使用 Portlane 主题，取消退出保留 relay、游戏监测与自动插帧订阅。
- Wine 准备超时重试与诊断、NVAPI 别名、共享 Steam 的 CLR 默认兼容策略已移植；保留用户明确配置的单游戏覆盖和启动诊断；《悟空》不再追加自动 CLR 特例。
- 下载数据解析选择性合入，Play relay 的拦截、租约与去重保留；云同步状态仅在后台维护，用户在官方 Steam 中查看；仅保留退出／重启受阻时的必要提示。
- 插帧的处理预算、显示调度、有界队列、可见性保护及实际呈现 watchdog 已移植；仍默认关闭。
- 打包本地化检查兼容 Xcode／SwiftPM；原 Portlane DMG 脚本已具备上游资源布局修复，保留自身品牌、图标及运行时地址。完整检查脚本已纳入 JavaScript 与本地化源码检查。
- 验证记录见 [本轮本地验证](validation/portlane-upstream-port-20261011.json)。上游游戏测试结果没有计为本轮 Portlane 验收。

以下保留移植取舍及验收要求，供后续实机验证使用。

Portlane 基线为 `4cb917f05e76d1dc2f974b79f2818f19e5129415`。上游 Mac Gaming Uncle 基线为 `2cd8d61e65ccb04ffcec0f85d5156b1c5ddcab12`（0.6.1），我们的原 PR 末端为 `affc39dca3347549665a595a9ea48d58f2f73608`。以下内容依据实际提交差异及发布记录，避免把原 PR 的空间音频、Wine 版本管理、搜索与窗口快捷键重复计入上游新增工作。

Portlane 保持 Steam 兼容性伴侣定位：商店、游戏库、下载管理由官方 Windows Steam 承担；保留现有品牌、统一界面、Play relay、每游戏配置、启动诊断和游戏退出后的焦点返回。

## 来源

- [bf1ada9：Steam 生命周期、下载指标与 Wine 初始化恢复](https://github.com/enginefuture/mac-gaming-uncle/commit/bf1ada9b6c2e857c639534595772a20cb2ff19b4)。
- [0.6.0 发布提交](https://github.com/enginefuture/mac-gaming-uncle/commit/2db077053c8646ca19124339fc0ad91c8c36a672)：运行时交付、安装包与本地化检查。
- [0.6.1 发布提交](https://github.com/enginefuture/mac-gaming-uncle/commit/2cd8d61e65ccb04ffcec0f85d5156b1c5ddcab12)：插帧呈现重构与云日志修复。
- [0.6.0 发布记录](https://github.com/enginefuture/mac-gaming-uncle/blob/2db077053c8646ca19124339fc0ad91c8c36a672/docs/releases/0.6.0.md)、[0.6.1 发布记录](https://github.com/enginefuture/mac-gaming-uncle/blob/2cd8d61e65ccb04ffcec0f85d5156b1c5ddcab12/docs/releases/0.6.1.md)。

## 优先级与范围

| 顺序 | 改动 | 决定 | 对 Portlane 的价值 |
| --- | --- | --- | --- |
| 1 | Steam 云存档退出／重启保护，含 CRLF 修复 | 优先移植 | Portlane 会改变共享 Steam 环境并重启会话，必须避免中断游戏退出后的云上传 |
| 2 | Wine 字体／显示配置超时恢复 | 优先移植 | 降低首次启动和配置应用时的失败，提供可定位的诊断 |
| 3 | GPTK NVAPI 文件别名 | 优先移植 | 修复部分游戏隐藏 DLSS 选项的加载问题 |
| 4 | Steam 下载指标可靠性 | 选择性移植 | 让 Play relay 的重启阻止条件依据有效下载状态，避免恢复下载管理界面 |
| 5 | SwiftPM／Xcode 打包与本地化检查 | 适配移植 | 保证 Portlane 发行包中英文资源完整 |
| 6 | 通用插帧呈现、性能预算及保护机制 | 独立阶段移植 | 改善现有实验插帧的延迟、稳定性及诊断可信度，变更范围较大 |
| — | 上游空间音频运行时地址、品牌与完整 Steam UI | 不直接移植 | Portlane 已有自己的运行时地址和产品定位 |

## 1. Steam 云存档保护

上游新增 `Sources/IndieRuntime/SteamCloudLog.swift`，并修改应用模型、Steam 激活和退出流程；0.6.1 修复 Windows CRLF 换行及不完整的末尾上传确认。两部分应一起移植，避免引入已知日志解析缺陷。

Portlane 当前入口包括 `MacGamingUncleAppModel.shutdownManagedSteam()`、`MacGamingUncleApplication.swift` 的退出委托，以及模型中 Play relay 改变共享 Steam 环境后的重启路径。必须逐处整合，不能只替换退出方法或覆盖整个上游应用模型。

目标行为：

- 按账户、AppID 和本次运行起始时间记录待上传状态，并跨应用启动保留。
- 只有匹配账户和游戏的完整退出上传确认才能解除保护；下载完成、单文件上传成功、历史记录不能替代整批确认。
- 退出或环境变更需要重启 Steam 时，先检查游戏和下载，再等待云同步（上游最多 60 秒）。
- 未确认上传完成时保留 Steam；用户可以取消退出继续等待，或仅退出 Portlane。
- 正常关闭使用 Steam `-shutdown`。初始化失败清理与正常会话退出应分开处理。
- 日志只读，限制尾部读取量，忽略残缺行；不改写游戏存档或 `remotecache.vdf`。

Portlane 适配：退出提示使用现有 `SteamTheme`，保留 Play relay 的租约／去重和 `GameFocusReturn` 行为。云同步状态在后台维护，仅在操作受阻时提示；Steam 联机不能视为云存档上传完成。

验证：移植 `SteamCloudLogTests`，覆盖账户切换、失败／新批次、运行时间、CRLF、残缺末行、历史确认及无变更退出；补充 Portlane 的退出、relay 重启和未确认时保留 Steam 的行为检查。最终使用支持云存档的游戏完成一次真实退出上传和另一设备下载核对；日志单元测试不能替代跨设备验收。

## 2. Wine 初始化超时恢复

移植 `RuntimeProvider.swift` 的有界 `runPreparation`，用于字体注册与 Steam 显示配置；更新 `SteamCompatibilityManager.swift` 的调用方式。

仅在准备阶段超时后清理残留 Wine helpers 并重试一次。非超时错误保留原错误，不自动重试。连续超时需显示具体操作和 Bottle 下 `.indie-diagnostics/wine-preparation.log` 路径。

必须在游戏／Steam 启动之前执行；不能将这种 Bottle 清理复用到游戏运行中或云上传等待期间。保留 Portlane 现有启动进度与诊断展示。

验证：移植 `WinePreparationRecoveryTests`，覆盖第一次超时后成功、连续超时、非超时失败，并验证包含中文和空格的路径。

## 3. NVAPI 兼容修复

在 `D3DMetalRendererPreparer.enableMetalFX()` 中补齐上游别名：`nvapi64.dll → nvapi.dll` 与 `nvapi64.so → nvapi.so`。上游说明 Wine builtin 名称使用 `nvapi.dll`，缺少别名可能导致初始化失败而隐藏 DLSS。

保留既有备份、错误处理和用户导入 GPTK 的方式，不覆盖现有文件，也不把 Apple 二进制纳入发行包。UI 沿用实验 MetalFX/DLSS 映射的表述。

验证：覆盖缺失文件、重复执行与已有目标文件，再用用户导入的 GPTK 验证游戏实际可选择 DLSS，核对启动日志是否仍有 DLL 初始化错误。

## 4. 下载状态可靠性

选择性移植 `SteamDownloadBridge.swift` 的有效字节数、阶段、时间戳和过期状态清理，以及 `SteamTransferMetrics.swift` 中确实用于 Portlane 的逻辑。

Portlane 的桥接文件还包含自己的 Steam Play 拦截与上下文处理，不能直接用上游文件替换。只改下载数据解析，保留 RunGame 包装、原始调用参数、租约、去重和断线恢复。

使用场景是 relay 重启前判断是否存在活动下载，以及诊断；不重新加入商店、库页或完整下载 UI。未知／过期状态不能伪装成下载已结束或允许安全重启。

验证：更新 `scripts/test-steam-bridge.mjs`，继续运行 `scripts/test-steam-launch-relay.mjs` 和 `scripts/test-steam-presentation.mjs`；覆盖远程下载事件、本地队列、暂停、校验、状态过期与无法读取状态时的重启阻止。

## 5. 发行与资源检查

适配上游 `scripts/build-dmg.sh` 和 `scripts/check-packaged-localization.sh` 对 SwiftPM 与 Xcode 资源布局的兼容修复，保留 Portlane 应用名、图标、包标识、DMG 文件名和版本体系。

Portlane 的 `CommunityIndieWineBootstrapper.swift` 已指向自身 v0.5.1 的 `portlane-wine-11.0.9-services.1-macos-x86_64.tar.xz`，并配置 SHA-256 与大小。因此不照搬上游下载地址，也无需仅因上游 0.6.0 发布而重建相同音频运行时。

如后续需要更新运行时，应独立确认补丁、哈希、大小、架构与构建来源，再使用 Portlane 自己的发行流程。上游测试记录不能直接当作 Portlane 制品验收记录。

验证：Release 构建，检查实际打包后的中英文资源、名称／图标、签名和 DMG 内容；对 Portlane 发布归档执行导入与 Bottle 初始化冒烟。

## 6. 通用插帧独立阶段

这是现有实验功能的重构，建议在前三项稳定后实施。上游新增与修改的主要组成包括：

- Core：`FrameInterpolationPlan`、`FrameInterpolationPresentationHealth`、`FrameInterpolationVisibilityGate`、`FrameInterpolationWindowLayer`。
- Runtime：`InterpolationFrameAnalyzer`。
- App：`InterpolationMetalPresenter`、`GameFrameInterpolation`、自动跟随与控制面板。
- 配套：预测／呈现／可见性测试、探针、构建脚本及诊断说明。

应整体迁移相互依赖的捕获、处理、排队、呈现与退出逻辑，不能只加入显示定时器：

- 捕获上限 30 FPS，处理尺寸按 1280×720 预算并对齐，用 MetalFX Spatial 放大到原窗口物理尺寸；保留游戏分辨率和 Wine DPI。
- 使用 `CAMetalDisplayLink`、有界 GPU 队列和 owned buffer pool；及时释放捕获 surface，只处理最新待处理画面。
- 重复帧与场景切换分析移出 UI 线程；处理超时或呈现停滞时恢复游戏原画面。
- 非激活、鼠标穿透的覆盖层，严格绑定进程和窗口身份；识别上游实测 Wine 图层，但不视为所有游戏通用保证。
- 窗口不可见立即隐藏，最多允许一秒同窗口恢复；epoch 拒绝跨间隙任务，焦点／窗口／屏幕变化重新核验或停止。
- 分开统计提交、生成与实际呈现；停止后保留诊断，不把覆盖层呈现频率标为游戏 FPS。

Portlane 适配：保留现有品牌与 `SteamTheme`、默认关闭和 macOS 26 条件；与游戏退出焦点返回、relay 启动及手动停止抑制自动重启的逻辑一起检查。

验证：先运行相关单元测试和独立捕获／呈现探针，再对实际 Portlane 打包应用做启动、切屏、窗口变化、手动停止、重启和游戏退出检查；最后测战斗拖影、HUD、输入延迟、长时间运行及多显示器。

上游《黑神话：悟空》证据来自约五分钟固定场景的独立探针：游戏 HUD 约 40 FPS，覆盖层平均 52.30 次独立画面呈现回调／秒。它不证明稳定 60 FPS、引擎性能翻倍或 Portlane 已通过验收；测试末尾因切换应用触发退出。直接 1920×1080 处理曾失败，首次呈现间歇故障与战斗质量仍需验证。

## 实施方式与完成标准

不要整体合并或直接 cherry-pick `bf1ada9`、`2db0770`、`2cd8d61`：它们同时涉及上游品牌、版本、UI 和应用模型，与 Portlane 独立开发有重叠。按上述顺序移植功能及相关测试，每个阶段保留来源提交与署名。

前三项可作为一次稳定性更新；下载与包装适配可随后补入；插帧单独安排完整验证。完成一个阶段后记录实际 Portlane 提交、检查结果和未验证项，更新本文件状态。未经 Portlane 实际运行和制品检查，不沿用上游版本号或发布记录中的通过结论。
