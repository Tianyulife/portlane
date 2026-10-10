import SwiftUI
import IndieCore
import IndieCatalog

struct SteamInstallTarget: Identifiable {
    let id: UInt64
    let name: String
}

struct SteamStorageView: View {
    @EnvironmentObject private var model: MacGamingUncleAppModel
    @Environment(\.dismiss) private var dismiss
    var target: SteamInstallTarget? = nil
    @State private var selection: String?
    private var selected: SteamLibraryLocation? { model.steamLibraries.first { $0.id == selection } }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {
                VStack(alignment:.leading,spacing:5) {
                    Text(target.map { L("安装 \($0.name)") } ?? L("存储与游戏库")).font(.title2.bold())
                    Text(L("选择磁盘上的 Steam 游戏库，已有游戏无需重新导入文件")).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("关闭")) { dismiss() }
            }
            ScrollView {
                VStack(spacing:10) {
                    ForEach(model.steamLibraries) { library in
                        Button { selection = library.id } label: {
                            HStack(alignment:.top,spacing:12) {
                                Image(systemName: library.isAvailable ? "externaldrive.fill" : "externaldrive.badge.exclamationmark")
                                VStack(alignment:.leading,spacing:5) {
                                    Text(library.displayName + (library.volumeName.map { " · " + $0 } ?? "")).font(.headline)
                                    Text(library.displayPath).font(.caption).textSelection(.enabled)
                                    HStack {
                                        Text(library.isAvailable ? (library.isWritable ? L("可安装") : L("只读，无法安装")) : L("磁盘未连接或目录不可访问"))
                                        if let free = library.freeBytes {
                                            Text(L("可用空间") + " " + ByteCountFormatter.string(fromByteCount:free,countStyle:.file))
                                        }
                                    }.font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selection == library.id { Image(systemName:"checkmark.circle.fill").foregroundStyle(.blue) }
                            }.padding(14).frame(maxWidth:.infinity,alignment:.leading)
                                .background(RoundedRectangle(cornerRadius:3).fill(selection == library.id ? IndiePalette.control : IndiePalette.panel))
                        }.buttonStyle(.plain)
                    }
                }
            }
            Text(L("支持添加新文件夹或选择已有 SteamLibrary／steamapps。不要让多个 Steam 客户端同时写入同一游戏库；macOS 版游戏文件不一定可用于 Windows 版。"))
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.steamStorageError { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button(L("添加／挂载游戏库"),systemImage:"externaldrive.badge.plus") { Task { await model.chooseSteamLibraryFolder() } }
                Button(L("刷新"),systemImage:"arrow.clockwise") { model.refreshSteamLibraryLocations() }
                if model.isManagingSteamStorage { ProgressView().controlSize(.small) }
                Spacer()
                if let target {
                    Button(L("安装到所选游戏库")) {
                        guard let selected else { return }
                        model.pendingSteamInstall = nil
                        Task { await model.installSteamGame(appID:target.id,library:selected) }
                    }.buttonStyle(.borderedProminent)
                        .disabled(selected?.isWritable != true || model.isWorking || model.isManagingSteamStorage)
                }
            }.disabled(model.isManagingSteamStorage)
        }.padding(24).frame(width:720,height:540)
        .steamSurface().presentationBackground(IndiePalette.canvas)
            .onAppear {
                model.refreshSteamLibraryLocations()
                selection = model.preferredSteamLibraryID ?? model.steamLibraries.first?.id
            }
    }
}

struct SteamOfflineLibraryNotice: View {
    @EnvironmentObject private var model: MacGamingUncleAppModel
    let library: SteamLibraryLocation
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            Label(L("游戏所在磁盘未连接"),systemImage:"externaldrive.badge.exclamationmark")
            Text(library.displayPath).font(.caption).foregroundStyle(.secondary)
            Button(L("管理游戏库")) { model.showSteamStorage = true }
        }
    }
}
