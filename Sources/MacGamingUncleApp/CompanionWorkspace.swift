import AppKit
import IndieCore
import SwiftUI
import UniformTypeIdentifiers

struct CompanionSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(title).font(.title2); Spacer(); Button(L("完成")) { dismiss() } }.padding(20)
            Divider()
            content()
        }.frame(minWidth: 760, minHeight: 640)
            .steamSurface().presentationBackground(IndiePalette.canvas)
    }
}

struct GameConfigurationWorkspace: View {
    @EnvironmentObject private var model: MacGamingUncleAppModel
    @Binding var hasUnsavedChanges: Bool
    @State private var selectedID: String?
    @State private var pendingID: String?

    private var targets: [GameSettingsTarget] {
        let steam = (model.steamGames + model.steamDownloads).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map {
            GameSettingsTarget(id: GameConfiguration.steam(appID: $0.appID).id, name: $0.name,
                detail: "Steam · \($0.appID)", configuration: model.configuration(for: $0))
        }
        let local = model.games.map {
            GameSettingsTarget(id: GameConfiguration.local(gameID: $0.id).id, name: $0.displayName,
                detail: L("本地程序"), configuration: model.configuration(for: $0))
        }
        return steam + local
    }
    private var selection: String? { selectedID ?? targets.first?.id }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("游戏配置")).font(.system(size: 24, weight: .medium))
                    Text(L("调整游戏在 Mac 上的运行方式")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !targets.isEmpty {
                    SteamPicker(title: L("配置对象"), selection: Binding(
                        get: { selection ?? "" }, set: { requestSelection($0) }
                    ), choices: targets.map { ($0.name, $0.id) })
                    .frame(maxWidth: 320)
                }
                SteamActionMenu(title: L("更多操作"), systemImage: "ellipsis", actions: [
                    .init(title: L("导入本地 EXE"), action: importExecutable),
                    .init(title: L("重新扫描 Steam 游戏"), action: { model.rescanSteam() }),
                    .init(title: L("Steam 游戏库"), action: { Task { await model.openSteamClient() } })
                ])
            }.padding(24)
            Divider()
            if let target = targets.first(where: { $0.id == selection }) {
                GameSettingsView(target: target, embedded: true, hasUnsavedChanges: $hasUnsavedChanges).id(target.id)
                if target.id.hasPrefix("local:"), let game = model.games.first(where: { GameConfiguration.local(gameID: $0.id).id == target.id }) {
                    HStack { Text(L("本地程序由 Mac 管理器启动")).foregroundStyle(.secondary); Spacer()
                        Button(L("运行本地程序"), systemImage: "play") { Task { await model.play(game) } }.disabled(model.isWorking || hasUnsavedChanges)
                    }.font(.caption).padding(16)
                }
            } else {
                ContentUnavailableView {
                    Label(L("没有可配置的游戏"), systemImage: "slider.horizontal.3")
                } description: { Text(L("在官方 Steam 中安装游戏，或导入本地 Windows 程序。")) }
                actions: {
                    Button(L("打开 Windows Steam")) { Task { await model.openSteamClient() } }
                    Button(L("导入本地 EXE")) { importExecutable() }
                }
            }
        }
        .steamDialog(L("放弃未保存的游戏设置？"), isPresented: Binding(
            get: { pendingID != nil }, set: { if !$0 { pendingID = nil } }
        )) {
            Button(L("放弃修改"), role: .destructive) {
                selectedID = pendingID; pendingID = nil; hasUnsavedChanges = false
            }
            Button(L("继续编辑"), role: .cancel) { pendingID = nil }
        }
        .onChange(of: targets.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = nil; hasUnsavedChanges = false }
        }
    }

    private func requestSelection(_ id: String) {
        guard id != selection else { return }
        if hasUnsavedChanges { pendingID = id } else { selectedID = id }
    }
    private func importExecutable() {
        if let url = SteamFileDialog.choose(title: L("导入本地 EXE"), extensions: ["exe"]) {
            Task { await model.importExecutable(url) }
        }
    }
}

struct CompanionRuntimeView: View {
    @EnvironmentObject private var model: MacGamingUncleAppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("运行组件")).font(.system(size: 24, weight: .medium))
                    Text(L("管理 Mac 兼容层与共享运行环境")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.steamExecutable == nil {
                    Button(L("安装 Windows Steam")) { Task { await model.installSteam() } }.disabled(model.isWorking)
                } else {
                    Button(L("Steam 下载管理")) { Task { await model.openSteamClient(.downloads) } }
                }
            }.padding(24)
            Divider()
            RuntimeSettingsContent()
            DisclosureGroup(L("高级：Bottle 与本地目录")) {
                ForEach(model.bottles) { bottle in
                    HStack { Text(bottle.name); Spacer(); Button(L("打开目录")) { NSWorkspace.shared.open(bottle.root) } }
                }
                Text(L("Steam 游戏共享 Bottle；游戏配置分别保存。共享环境修改会影响其中所有游戏。"))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.bottom, 20)
        }
    }
}

struct CompanionDiagnosticsView: View {
    @EnvironmentObject private var model: MacGamingUncleAppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("诊断")).font(.system(size: 24, weight: .medium))
                    Text(model.steamLaunchRelayActive ? L("官方 Steam 的开始游戏操作已接入 Mac 配置") : L("打开官方 Steam 并等待连接后，开始游戏操作才能应用 Mac 配置"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("打开运行日志")) { NSWorkspace.shared.open(model.paths.logs) }
            }.padding(24)
            Divider()
            if !model.steamLaunchRelayActive, !model.steamLaunchRelayDetail.isEmpty {
                Text(model.steamLaunchRelayDetail).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 12)
            }
            GameLaunchProgressView()
            DiagnosticsContent()
        }
    }


}
