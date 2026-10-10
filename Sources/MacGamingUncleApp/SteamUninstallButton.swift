import SwiftUI
import IndieCore
import IndieCatalog

struct SteamUninstallButton: View {
    @EnvironmentObject private var model: MacGamingUncleAppModel
    let game: SteamGame
    @State private var confirming = false
    var body: some View {
        Button(model.uninstallingSteamAppIDs.contains(game.appID) ? L("正在卸载…") : L("卸载游戏"), systemImage: "trash") {
            confirming = true
        }
        .disabled(model.isWorking || model.uninstallingSteamAppIDs.contains(game.appID) || model.gameLaunchStates[game.appID]?.blocksLaunch == true)
        .steamDialog(L("卸载 \(game.name)？"), isPresented: $confirming) {
            Button(L("卸载游戏"), role: .destructive) { confirming = false; Task { await model.uninstallSteamGame(game) } }
            Button(L("取消"), role: .cancel) { confirming = false }
        } message: {
            Text(L("将通过 Steam 移除游戏安装文件，需要重新下载才能游玩。不会额外清理存档、配置或云数据。"))
        }
    }
}
