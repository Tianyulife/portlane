import AppKit
import IndieCore
import SwiftUI

/// App-owned file selection keeps import workflows on the same opaque surfaces.
@MainActor
enum SteamFileDialog {
    static func choose(title: String, extensions: Set<String> = [], directories: Bool = false, createDirectories: Bool = false) -> URL? {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.isOpaque = true
        panel.backgroundColor = NSColor(red: 0.106, green: 0.157, blue: 0.220, alpha: 1)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.minSize = NSSize(width: 760, height: 520)
        var result: URL?
        let delegate = ModalDelegate()
        panel.delegate = delegate
        panel.contentView = NSHostingView(rootView: SteamFileSelectionView(title: title, extensions: extensions,
            directories: directories, createDirectories: createDirectories) { url in
                result = url
                NSApp.stopModal(withCode: url == nil ? .cancel : .OK)
            })
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return result
    }

    private final class ModalDelegate: NSObject, NSWindowDelegate {
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            NSApp.stopModal(withCode: .cancel)
            return true
        }
    }
}

private struct ImportFileEntry: Identifiable {
    let url: URL
    let directory: Bool
    var id: String { url.path }
}

private struct SteamFileSelectionView: View {
    let title: String
    let extensions: Set<String>
    let directories: Bool
    let createDirectories: Bool
    let finish: (URL?) -> Void
    @State private var location = FileManager.default.homeDirectoryForCurrentUser
    @State private var path = ""
    @State private var entries: [ImportFileEntry] = []
    @State private var selected: URL?
    @State private var error: String?
    @State private var showHidden = false
    @State private var folderName = ""
    @State private var creatingFolder = false

    private var candidate: URL? { selected ?? (directories ? location : nil) }
    private var shortcuts: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let favorites = [home, home.appendingPathComponent("Desktop"), home.appendingPathComponent("Documents"), home.appendingPathComponent("Downloads")]
        let volumes = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return favorites + volumes.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(title).font(.system(size: 22, weight: .medium)); Spacer() }.padding(24)
            Divider()
            HStack(spacing: 12) {
                Button { load(location.deletingLastPathComponent()) } label: { Image(systemName: "arrow.up") }.disabled(location.path == "/")
                TextField(L("文件夹路径"), text: $path).textFieldStyle(.plain)
                    .padding(10).background(IndiePalette.control, in: RoundedRectangle(cornerRadius: 3))
                    .onSubmit { navigatePath() }
                Button(L("前往")) { navigatePath() }
            }.padding(18)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(shortcuts, id: \.path) { url in
                        Button { load(url) } label: {
                            Label(url == FileManager.default.homeDirectoryForCurrentUser ? L("个人文件夹") : url.lastPathComponent,
                                  systemImage: url.path.hasPrefix("/Volumes/") ? "externaldrive" : "folder")
                                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(location == url ? IndiePalette.control : .clear, in: RoundedRectangle(cornerRadius: 3))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }.padding(12).frame(width: 190).background(IndiePalette.sidebar)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(entries) { entry in
                            Button {
                                if entry.directory { load(entry.url) } else { selected = entry.url }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: entry.directory ? "folder.fill" : "doc").foregroundStyle(IndiePalette.blue)
                                    Text(entry.url.lastPathComponent).lineLimit(1)
                                    Spacer()
                                    if entry.directory { Image(systemName: "chevron.right").font(.caption) }
                                    else if selected == entry.url { Image(systemName: "checkmark").foregroundStyle(IndiePalette.blue) }
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selected == entry.url ? IndiePalette.control : IndiePalette.panel, in: RoundedRectangle(cornerRadius: 3))
                            }.buttonStyle(.plain)
                        }
                        if entries.isEmpty { Text(L("没有符合条件的文件")).foregroundStyle(.secondary).padding(24) }
                    }.padding(12)
                }
            }.frame(maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let error { Text(error).foregroundStyle(.orange).font(.caption) }
                Text(candidate?.path ?? L("请选择要导入的文件")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 12) {
                    Toggle(L("显示隐藏文件"), isOn: $showHidden).fixedSize()
                    if createDirectories { Button(L("新建文件夹")) { creatingFolder = true } }
                    Spacer()
                    Button(L("取消")) { finish(nil) }.keyboardShortcut(.cancelAction)
                    Button(directories && selected == nil ? L("选择当前文件夹") : L("导入")) { complete() }
                        .buttonStyle(SteamButtonStyle(prominent: true)).disabled(candidate == nil).keyboardShortcut(.defaultAction)
                }
            }.padding(18)
        }.steamSurface()
            .onAppear { load(location) }
            .onChange(of: showHidden) { _, _ in load(location) }
            .steamDialog(L("新建文件夹"), isPresented: $creatingFolder) {
                Button(L("取消")) { creatingFolder = false }
                Button(L("创建")) { makeFolder() }.disabled(folderName.trimmingCharacters(in: .whitespaces).isEmpty)
            } message: { TextField(L("文件夹名称"), text: $folderName).textFieldStyle(.plain).padding(10).background(IndiePalette.control) }
    }

    private func navigatePath() {
        load(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }
    private func load(_ url: URL) {
        do {
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                error = L("请选择文件夹路径"); return
            }
            let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: showHidden ? [] : [.skipsHiddenFiles])
            entries = files.compactMap { file in
                let isDirectory = (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                guard isDirectory || extensions.contains(file.pathExtension.lowercased()) else { return nil }
                return ImportFileEntry(url: file, directory: isDirectory)
            }.sorted { a, b in
                if a.directory != b.directory { return a.directory }
                return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
            }
            location = url.standardizedFileURL; path = location.path; selected = nil; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func complete() {
        guard let url = candidate else { return }
        do {
            let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            guard isDirectory ? directories : extensions.contains(url.pathExtension.lowercased()) else { return }
            finish(url)
        } catch { self.error = error.localizedDescription }
    }
    private func makeFolder() {
        let name = folderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0") else { error = L("文件夹名称无效"); creatingFolder = false; return }
        do {
            let url = location.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            creatingFolder = false; folderName = ""; load(url)
        } catch { self.error = error.localizedDescription; creatingFolder = false }
    }
}
