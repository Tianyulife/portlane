import AppKit
import IndieCore
import SwiftUI

@main
struct MacGamingUncleApplication: App {
    @NSApplicationDelegateAdaptor(UncleApplicationDelegate.self) private var appDelegate
    @StateObject private var model = MacGamingUncleAppModel()

    var body: some Scene {
        Window("Portlane", id: "steam-shell-main") {
            ContentView()
                .environmentObject(model)
                .environment(\.locale, AppLanguage.locale)
                .frame(minWidth: 1100, minHeight: 720)
                .onOpenURL { model.handleDeepLink($0) }
                .onAppear {
                    appDelegate.model = model
                    GameFocusReturn.shared.bind(model: model)
                    if #available(macOS 26, *) { AutomaticFrameInterpolation.shared.bind(model: model) }
                }
        }
        .commands { WindowOperationCommands() }
        .defaultSize(width: 1440, height: 920)
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))

        Settings {
            SettingsView()
                .environmentObject(model)
                .environment(\.locale, AppLanguage.locale)
                .frame(width: 620, height: 560)
        }
        WindowGroup(L("通用插帧（实验）"), id: "frame-interpolation", for: String.self) { id in
            if #available(macOS 26, *) {
                FrameInterpolationView(gameID: id.wrappedValue ?? "manual")
                    .environmentObject(model)
                    .environment(\.locale, AppLanguage.locale)
            } else {
                Text(L("通用插帧需要 macOS 26 或更新版本")).padding(32)
            }
        }
        .defaultSize(width: 620, height: 440)
        .commands {
            CommandMenu(L("通用插帧（实验）")) {
                Button(L("停止插帧")) {
                    if #available(macOS 26, *) { GameFrameInterpolation.shared.stop() }
                }
            }
        }
    }
}

@MainActor
final class UncleApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var model: MacGamingUncleAppModel?
    private var shutdownTask: Task<Void, Never>?
    private var quitConfirmationWindow: NSWindow?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if shutdownTask == nil {
            shutdownTask = Task { @MainActor in
                if await model.shutdownManagedSteam() {
                    if #available(macOS 26, *) { AutomaticFrameInterpolation.shared.shutdown() }
                    sender.reply(toApplicationShouldTerminate: true)
                } else {
                    self.showQuitConfirmation(sender)
                }
            }
        }
        return .terminateLater
    }

    private func showQuitConfirmation(_ sender: NSApplication) {
        let parent = sender.mainWindow
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("Steam 仍需要运行")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SteamQuitConfirmation(detail: model?.steamClientNotice ?? "") { [weak self] quitOnlyApp in
            self?.finishQuitConfirmation(sender, quitOnlyApp: quitOnlyApp)
        })
        quitConfirmationWindow = window
        if let parent { parent.beginSheet(window) }
        else { window.center(); window.makeKeyAndOrderFront(nil) }
    }

    private func finishQuitConfirmation(_ sender: NSApplication, quitOnlyApp: Bool) {
        guard let window = quitConfirmationWindow else { return }
        quitConfirmationWindow = nil
        window.sheetParent?.endSheet(window)
        window.close()
        shutdownTask = nil
        if quitOnlyApp, #available(macOS 26, *) { AutomaticFrameInterpolation.shared.shutdown() }
        sender.reply(toApplicationShouldTerminate: quitOnlyApp)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finishQuitConfirmation(NSApplication.shared, quitOnlyApp: false)
        return false
    }
}

private struct SteamQuitConfirmation: View {
    let detail: String
    let completion: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L("Steam 仍需要运行")).font(.system(size: 20, weight: .medium))
            Text(L("游戏、云存档上传或客户端退出尚未确认。可取消退出继续等待，或仅退出 Portlane 并保留 Steam 后台运行。"))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button(L("退出应用，保留 Steam")) { completion(true) }
                Button(L("取消退出，继续等待")) { completion(false) }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 520).steamSurface()
    }
}
