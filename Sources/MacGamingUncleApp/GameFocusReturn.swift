import AppKit
import Combine
import IndieCore
import IndieCatalog
import IndieRuntime

@MainActor
final class GameFocusReturn: ObservableObject {
    static let shared = GameFocusReturn()
    @Published private(set) var canReturn = false
    private var paths: Set<String> = []
    private var history = GameFocusHistory()
    private var runs: Set<GameFocusHistory.Run> = []
    private var subscription: AnyCancellable?
    private var loop: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var returning = false

    func bind(model: MacGamingUncleAppModel) {
        guard subscription == nil else { return }
        subscription = Publishers.CombineLatest3(model.$steamGames, model.$games, model.$bottles)
            .sink { [weak self, weak model] _, _, _ in
                Task { @MainActor in
                    guard let self, let model else { return }
                    self.configure(model: model)
                }
            }
        configure(model: model)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor in
                guard let self else { return }
                self.history.observe(runs: self.runs, foregroundPID: pid)
                self.canReturn = self.history.target != nil
            }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func configure(model: MacGamingUncleAppModel) {
        var paths: Set<String> = []
        if let bottle = model.steamBottle {
            for game in model.steamGames {
                if let executable = try? SteamExecutableResolver.shippingExecutable(for: game),
                   let path = try? WinePath.windowsPath(for: executable, in: bottle) { paths.insert(path) }
            }
        }
        for game in model.games {
            if let bottle = model.bottles.first(where: { $0.id == game.bottleID }),
               let path = try? WinePath.windowsPath(for: game.executableURL, in: bottle) { paths.insert(path) }
        }
        self.paths = paths
    }

    private func refresh() async {
        guard let processes = try? await GameProcessProbe.processes() else { return }
        var current: Set<GameFocusHistory.Run> = []
        for path in paths {
            let matching = processes.filter { GameProcessProbe.matches(command: $0.command, windowsPath: path) }
            // Same Windows path in multiple Bottles: do not guess which game owns it.
            if matching.count == 1, let process = matching.first {
                current.insert(.init(pid: process.pid, started: process.started))
            }
        }
        runs = current
        history.observe(runs: runs, foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        canReturn = history.target != nil
    }

    @discardableResult
    func returnToGame() async -> Bool {
        guard !returning, let expected = history.target else { return false }
        returning = true
        defer { returning = false }
        await refresh()
        guard runs.contains(expected), history.target == expected,
              let application = NSRunningApplication(processIdentifier: expected.pid),
              !application.isTerminated else { return false }
        let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        let hasWindow = windows.contains {
            guard ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == expected.pid,
                  ($0[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = $0[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return false }
            return frame.width >= 300 && frame.height >= 200
        }
        guard hasWindow else { return false }
        // A background controller command first needs activation rights before
        // transferring them to the Wine application's window-owning process.
        if !NSApp.isActive {
            NSApp.activate()
            for _ in 0..<10 {
                if NSApp.isActive { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        guard NSApp.isActive else { return false }
        NSApp.yieldActivation(to: application)
        application.unhide()
        return application.activate(options: .activateAllWindows)
    }
}
