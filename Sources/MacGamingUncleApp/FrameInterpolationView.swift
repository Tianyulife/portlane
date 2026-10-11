import SwiftUI
import IndieCore
import IndieRuntime

@available(macOS 26, *)
struct FrameInterpolationView: View {
    @EnvironmentObject private var model: MacGamingUncleAppModel
    @ObservedObject private var service = GameFrameInterpolation.shared
    @ObservedObject private var automatic = AutomaticFrameInterpolation.shared
    let gameID: String
    @State private var selected: UInt32 = 0

    private var enabled: Binding<Bool> {
        Binding(get: { model.gameConfigurations[gameID]?.frameInterpolation == true }, set: { value in
            var config = model.gameConfigurations[gameID] ?? GameConfiguration(id: gameID)
            config.frameInterpolation = value
            Task { await model.saveGameConfiguration(config) }
        })
    }
    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("通用插帧（实验）")).font(.title2.bold())
            Text(gameID).font(.caption).foregroundStyle(.secondary)
            Toggle(L("游戏启动后自动跟随窗口启用 2× 插帧"), isOn: enabled)
            Text(L("只处理游戏画面，不录音、不改 DPI。插帧提高显示流畅度，不提高游戏逻辑帧率；可能增加延迟和 HUD 重影。"))
                .font(.callout).foregroundStyle(.secondary)
            Text(L("插帧最高以 30 FPS、1280×720 捕获，目标为 2× 输出，再放大到原窗口尺寸；游戏分辨率保持不变。持续超时则显示原画面。"))
                .font(.callout).foregroundStyle(.secondary)
            Text(L("支持窗口／无边框模式。启动游戏后自动匹配；切出暂停、返回恢复。手动停止后，本次游戏运行不再自动开启。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(automatic.statuses[gameID] ?? L("开启后等待游戏启动，无需手动选择窗口"))
                .font(.callout).textSelection(.enabled)
            HStack {
                Button(L("授权录屏／刷新")) { Task { await service.refreshWindows() } }
                Button(L("重新允许本次运行自动启动")) { automatic.rearm(gameID: gameID) }
                    .disabled(!enabled.wrappedValue)
                Button(L("停止插帧")) { service.stop() }
                    .disabled(!service.active && !enabled.wrappedValue)
            }
            DisclosureGroup(L("手动选择窗口（备用）")) {
              HStack {
                SteamPicker(title: L("游戏窗口"), selection: $selected, choices: [(L("请选择正在显示的游戏窗口"), UInt32(0))] + service.windows.map { ("\($0.owningApplication?.applicationName ?? "") · \($0.title ?? "")", $0.windowID) })
                Button(L("刷新窗口")) { Task { await service.refreshWindows() } }
            }
              HStack {
                Button(L("启动 2× 插帧")) { Task { await service.start(windowID: selected) } }
                    .buttonStyle(SteamButtonStyle(prominent: true))
                    .disabled(!enabled.wrappedValue || selected == 0 || service.active || !FrameInterpolationEngine.isSupported)
              }
            }
            Text(L("全局紧急停止：Control + Option + Command + F12"))
                .font(.callout.bold())
            Divider()
            Text(service.status).textSelection(.enabled)
            Text(service.metrics).font(.caption.monospaced()).textSelection(.enabled)
            Text(L("提交帧数不是实测显示 FPS。窗口变形、切出游戏或设备处理失败时自动停止。呈现计数来自显示回调，仍不代表游戏逻辑帧率。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
      }
        .frame(minWidth: 600, minHeight: 480)
        .steamSurface()
        .task { automatic.bind(model: model) }
    }
}
