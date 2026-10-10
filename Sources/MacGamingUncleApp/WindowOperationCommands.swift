import AppKit
import IndieCore
import SwiftUI

struct ControllerWindowReturnButton: View {
    @ObservedObject var manager: ControllerManager
    @ObservedObject private var gameFocus = GameFocusReturn.shared

    var body: some View {
        if !manager.devices.isEmpty {
            Button {
                if gameFocus.canReturn {
                    Task { await gameFocus.returnToGame() }
                } else { manager.minimizeCompanionWindow() }
            } label: {
                Label(gameFocus.canReturn ? "≡ + B · " + L("返回当前游戏") : "B · " + L("最小化窗口"), systemImage: "gamecontroller")
            }
            .font(.caption)
        }
    }
}

/// Use the responder chain so commands operate on the active native window.
/// Close (Command-W) remains the standard File menu command.
struct WindowOperationCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .windowSize) {
            Button(L("最小化窗口")) {
                NSApp.sendAction(#selector(NSWindow.performMiniaturize(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("m", modifiers: .command)

            Button(L("最大化或恢复窗口")) {
                NSApp.sendAction(#selector(NSWindow.performZoom(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("m", modifiers: [.control, .command])

            Button(L("进入或退出全屏")) {
                NSApp.sendAction(#selector(NSWindow.toggleFullScreen(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("f", modifiers: [.control, .command])
        }
    }
}
