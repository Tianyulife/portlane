# Mac compatibility companion

The local app now owns compatibility settings rather than reproducing Steam's store and library. The current source is maintained in the independent Portlane repository.

## Pages

| Entry | Retained features |
| --- | --- |
| Game configuration | Installed/updating Steam game selector, local EXE import and launch, renderer selection, Metal HUD/MetalFX/Metal 4, synchronization, Wine virtual desktop and resolution, interpolation panel, per-game DLL overrides and environment variables, controller bridging/rumble, spatial audio diagnostics |
| Runtime components | Wine install/import/select/delete, GPTK install/cancel/import, DXMT/DXVK/VKD3D import, Bottle directories, Windows Steam installation, link to official Steam downloads |
| Diagnostics | System checks and refresh, Steam Play relay status/errors, per-game launch status, runtime log folder |
| Mac controllers | Device discovery and existing controller tools, opened from the sidebar |
| Global preferences | Language and global rendering defaults, opened from the sidebar and standard macOS Settings |
| First run | Existing environment setup and Steam sign-in flow |

Home, Store and Library are removed from the visible navigation. Purchase, installation, updates, downloads, Steam Input, achievements and launch arguments stay in Windows Steam. Legacy store/library source is retained internally for compatibility while it is no longer a user-facing destination. Old navigation deep links map to the new configuration area or official Steam.

## Steam Play relay

`SteamDownloadBridge` uses the existing private CEF pipe transport to install a leased `SteamClient.Apps.RunGame` wrapper in the official desktop and SharedJS contexts. Only locally discovered managed AppIDs are intercepted; other AppIDs and non-Steam shortcut GameIDs keep their original native call and arguments. Interception happens before game process creation.

The native app drains and deduplicates Play requests, resolves the saved per-game launch plan, then launches using Steam's own `-applaunch`/launch dialog contract. This native path does not go through the UI wrapper, avoiding a loop. Steam remains responsible for executable selection, authentication, ownership, launch-option dialogs and updates. The existing per-game settings and recipes remain in force.

Changing the inherited environment may require restarting the shared Steam Bottle. The app refuses this while another installed game is running or an active download is in progress. A connected client's download state must be checked successfully before restart. Pending/updating game records also participate in the relay; a readable executable is still required for compatibility analysis.

Keep the Mac manager open and wait for “Steam Play relay connected” before playing from Steam. Hooks reconnect after CEF/Steam restarts. The lease expires after 15 seconds without a live manager, restoring the original Steam method rather than indefinitely trapping Play. External Windows shortcuts, direct EXE execution and Steam URI launches outside the desktop UI are not covered by this UI interception. Steam's private API may change: failures are reported in Diagnostics instead of claiming connection success.

## Configuration storage

`GameConfiguration` has optional DLL overrides and environment variables; existing saved configurations decode without migration. DLL overrides are merged after renderer/recipe defaults. Reserved Bottle, Steam identity and host-path fields cannot be overwritten through the environment editor. Invalid names, duplicate UI keys and unsafe values fail validation before saving.

Wukong AppID 2358720 keeps its verified built-in `mscoree=b` rule. “Restore recommended” clears user overrides while retaining this runtime preset. Ordinary games retain the previous default DLL rules. Local programs retain their separate Bottles and launch arguments.

## Verification

- Full Swift suite: 111 tests executed, 4 optional integrations skipped, no failures.
- Production JavaScript tests: Play interception before native launch, duplicate clicks, unmanaged calls, original receiver/arguments, lease expiry, reconnect and read-only API failure; existing download/presentation tests pass.
- Local release app builds and signature verification pass. Previous installed local app is backed up in `dist`.
- Actual Windows Steam `RunGame` entry point was submitted for Wukong while the Mac manager was running. The relay prepared a new Steam session, Steam tracked both Wukong executables, and the game produced fresh Unreal/V8 initialization and rendering logs. The persisted session contains D3DMetal, Metal 4, renderer overrides and `mscoree=b`.

Evidence is saved in the workspace `work/diagnostics/steam-companion-tests.log` and `steam-companion-live-launch.log`. This validates the launch handoff, not every Steam UI variant or extended gameplay stability.

## Unified native appearance

The Mac companion uses opaque Steam blue-grey surfaces for the main window, preferences, controller management, interpolation, storage and confirmation sheets. Settings sections use plain scrollable panels instead of the system grouped Form/List background. Shared buttons, checkbox toggles and choice popovers avoid the system grey/glass appearance; choice controls retain accessible labels and current values.

Startup checks run inside the main shell. A fully installed environment with a completed Steam login goes directly to the workspace, avoiding the brief first-install page. Actual installation/login uses the same opaque runtime setup page.

Local verification: release build and codesign verification passed; 111 Swift tests executed with 4 optional skips and no failures. The installed app was reopened and the preferences sheet, choice popover, diagnostics and Wine deletion confirmation were inspected; confirmation was cancelled and no runtime was deleted.

The workspace More actions and resolution presets now use the same opaque action popovers. All retained import entry points use the app-owned file dialog (EXE, GPTK, Wine, renderer directories and Steam storage). It supports path navigation, mounted volumes, hidden files, extension filtering, cancellation and folder creation where allowed. Manual verification used a fixture directory: only the folder and EXE appeared, TXT was filtered, selecting the EXE enabled Import, and Cancel returned to the unchanged workspace. The fixture was not imported or executed.

The previous Update Channel preference was inert: only its UI read/wrote `releaseChannel`; runtime installers never consulted it and no application updater used it. The misleading control was removed. Runtime manifest channel metadata remains intact, and Steam still updates itself.

## Portlane identity

The local app is now Portlane (引航), with a Steam blue-black tile and a MacBook screen displaying the original circular Steam icon. The window, display copy, app bundle and DMG use the new name. Reproduce the PNG/iconset with `swift scripts/render-portlane-icon.swift`, then build `Assets/Portlane.icns` with iconutil. The SVG contains editable MacBook geometry and embeds the original Steam PNG. Assets/SteamOriginal.png is extracted from the locally installed Steam.app ICNS; the renderer scales it uniformly without recoloring or redrawing.

The original bundle identifier, preference domain, Bottle/runtime paths, runtime marker comparisons and executable/package target names remain stable so the rename preserves existing Steam login and game configuration. `portlane://` is added while legacy URL aliases continue to work. Old runtime display names are mapped at presentation time; installed manifests are not rewritten. No Dock behavior or Wine runtime binary has been changed.

The surrounding tile and screen use an explicit sRGB navy-to-blue gradient (#0c1e3b / #176c97) coordinated with Steam. The original Steam circle is enlarged by 50% (600 px source placement versus 400 px); a thin silver MacBook outline and lower chassis identify the Mac. Its original artwork and gradient are preserved. SVG, PNG, 16–1024 px iconset, app ICNS and the packaged in-app mark are synchronized. Large and small previews were inspected.

## Controller return to game

The companion observes background GameController events. Menu (≡) + B explicitly requests return to the most recently foregrounded managed game; ordinary B is only handled while the companion is foreground. The header offers the same return action when a target exists, otherwise it offers minimization.

Targets are matched against known game executable paths and their PID/start-time identity. Unrelated applications do not replace the remembered game; exited or reused process identities are discarded, and ambiguous executable matches are excluded. Before activation, the process identity and a normal game-sized window are checked again. The companion acquires activation rights and transfers them to the game's native window-owning application. No screen capture or Accessibility permission is requested.

Xbox/Home remains a macOS system action. The Menu+B chord avoids depending on delivery of that reserved button. Automated tests cover focus history and stale identities; physical-controller return from the system Dock/overlay still requires live validation.

### 游戏启动进度

主界面右下角在每次 Steam 游戏启动时显示一行状态，确认游戏进程已运行后自动消失；失败或未确认时保留提示，点击可进入诊断查看详情。详细启动面板位于诊断页，覆盖 Portlane 启动入口和官方 Steam Play 衔接。步骤包括文件/运行组件检查、兼容性分析、单游戏配置、Steam 会话准备、发送命令及等待进程，记录各阶段耗时。启动命令提交成功不等于游戏运行成功，只有进程探测成功才显示“检测到游戏进程”。120 秒内没有发现进程会标为“未能确认”，进程短时间退出也会保留提示，不推断具体崩溃原因。

诊断页的错误和时间线在本次应用运行期间保留，不受关闭通用错误提示或切换页面影响；可展开详情、复制诊断、打开启动日志。多个游戏的最近一次启动可在面板中切换，重试会刷新该游戏记录。启动面板不会自动抢占游戏焦点。

### 默认空间音频运行时

首次环境准备自动从 Portlane Release 下载 Wine `11.0.9-services.1`，按固定大小与 SHA-256 校验后安装。无需额外手动导入；已有安装不强制切换用户选择的运行时，仍可在运行组件中安装最新版本并选择服务版。单独的 Wine 压缩包继续提供手动/离线导入。
