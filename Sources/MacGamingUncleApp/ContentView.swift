import AppKit
import IndieCatalog
import IndieCore
import IndieRuntime
import SwiftUI
import UniformTypeIdentifiers

enum CompanionDestination: String, CaseIterable {
    case games, runtime, diagnostics
}

enum IndiePalette {
    static let canvas = Color(red: 0.106, green: 0.157, blue: 0.220)
    static let sidebar = Color(red: 0.090, green: 0.118, blue: 0.161)
    static let topBar = Color(red: 0.090, green: 0.102, blue: 0.129)
    static let surface = Color.white.opacity(0.060)
    static let surfaceStrong = Color.white.opacity(0.105)
    static let panel = Color(red: 0.126, green: 0.185, blue: 0.255)
    static let control = Color(red: 0.157, green: 0.216, blue: 0.286)
    static let border = Color.white.opacity(0.085)
    static let primary = Color(red: 0.15, green: 0.39, blue: 0.54)
    static let blue = Color(red: 0.40, green: 0.75, blue: 0.96)
    static let green = Color(red: 0.63, green: 0.80, blue: 0.44)
    static let secondaryText = Color.white.opacity(0.58)
}

struct ContentView: View {
    @EnvironmentObject private var model: MacGamingUncleAppModel
    @State private var destination: CompanionDestination = .games
    @State private var showPreferences = false
    @State private var showControllers = false
    @State private var hasUnsavedGameSettings = false
    @State private var pendingDestination: CompanionDestination?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                PortlaneMark(size: 28)
                Text(AppBrand.name).font(.system(size: 18, weight: .medium))
                Text(L("Mac 兼容设置")).font(.system(size: 13)).foregroundStyle(IndiePalette.secondaryText)
                Spacer()
                ControllerWindowReturnButton(manager: model.controllerManager)
                Label(model.steamLaunchRelayActive ? L("Steam 启动衔接已连接") : L("等待 Steam 启动衔接"),
                      systemImage: model.steamLaunchRelayActive ? "checkmark.circle.fill" : "circle")
                    .font(.caption).foregroundStyle(model.steamLaunchRelayActive ? IndiePalette.green : IndiePalette.secondaryText)
                Button(L("打开 Windows Steam"), systemImage: "arrow.up.forward.app") {
                    Task { await model.openSteamClient() }
                }.disabled(model.isOpeningSteamClient || model.isWorking)
            }
            .padding(.leading, 108).padding(.trailing, 24).frame(height: 60)
            .background(IndiePalette.topBar)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    navigation(L("游戏配置"), icon: "slider.horizontal.3", target: .games)
                    navigation(L("运行组件"), icon: "shippingbox", target: .runtime)
                    navigation(L("诊断"), icon: "waveform.path.ecg", target: .diagnostics)
                    Spacer()
                    Button(L("Mac 手柄管理"), systemImage: "gamecontroller") { showControllers = true }
                    Button(L("全局偏好设置"), systemImage: "gearshape") { showPreferences = true }
                    Text(L("商店、游戏库与下载\n由 Windows Steam 管理"))
                        .font(.caption).foregroundStyle(IndiePalette.secondaryText).padding(.top, 18)
                }
                .buttonStyle(.plain).padding(16).frame(width: 190).frame(maxHeight: .infinity)
                .background(IndiePalette.sidebar)
                VStack(spacing: 0) {
                    if let notice = model.steamClientNotice {
                        HStack {
                            Text(notice).font(.callout)
                            Spacer()
                            Button(L("关闭提示"), systemImage: "xmark") { model.steamClientNotice = nil }.labelStyle(.iconOnly)
                        }.padding(14).background(IndiePalette.surface)
                    }
                    if model.onboardingStage == .checking {
                        ProgressView(L("正在载入游戏配置…"))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else { switch destination {
                    case .games: GameConfigurationWorkspace(hasUnsavedChanges: $hasUnsavedGameSettings)
                    case .runtime: CompanionRuntimeView()
                    case .diagnostics: CompanionDiagnosticsView()
                    } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                if model.isWorking && !model.gameLaunchStates.values.contains(.preparing) { ProgressView().controlSize(.mini) }
                Text(model.isWorking && !model.gameLaunchStates.values.contains(.preparing) ? model.status : model.steamLaunchRelayActive ? L("保持 Mac 管理器打开，Steam 的开始游戏操作会先应用单游戏配置") : L("打开官方 Steam 并等待连接后，开始游戏操作才能应用 Mac 配置"))
                    .font(.caption).lineLimit(1)
                Spacer()
                if destination != .diagnostics {
                    GameLaunchStatusLine { select(.diagnostics) }
                }
            }.foregroundStyle(IndiePalette.secondaryText).padding(.horizontal, 20).frame(height: 30)
                .background(IndiePalette.topBar)
        }
        .steamSurface()
        .background(WindowPlacementReader().frame(width: 0, height: 0))
        .task {
            model.startSteamLaunchRelay()
            while !Task.isCancelled {
                await model.syncSteamLibrary()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .overlay {
            if model.onboardingStage == .environment || model.onboardingStage == .steam {
                FirstRunView().environmentObject(model)
            }
        }
        .onChange(of: model.requestedDestination) { _, request in
            guard let request else { return }
            switch request {
            case "store": Task { await model.openSteamClient(.storeFront) }
            case "controllers": showControllers = true
            case "environment": select(.runtime)
            case "diagnostics": select(.diagnostics)
            default: select(.games)
            }
            model.requestedDestination = nil
        }
        .preferredColorScheme(.dark)
        .steamDialog(L("无法完成操作"), isPresented: Binding(
            get: { model.lastError != nil && model.onboardingStage == .complete },
            set: { if !$0 { model.lastError = nil } }
        )) { Button(L("知道了")) { model.lastError = nil } }
        message: { Text(model.lastError ?? "") }
        .steamDialog(L("放弃未保存的游戏设置？"), isPresented: Binding(
            get: { pendingDestination != nil }, set: { if !$0 { pendingDestination = nil } }
        )) {
            Button(L("放弃修改"), role: .destructive) {
                if let next = pendingDestination { hasUnsavedGameSettings = false; destination = next }
                pendingDestination = nil
            }
            Button(L("继续编辑"), role: .cancel) { pendingDestination = nil }
        }
        .sheet(isPresented: $showPreferences) { CompanionSheet(title: L("全局偏好设置")) { PreferencesContent() } }
        .sheet(isPresented: $showControllers) { CompanionSheet(title: L("Mac 手柄管理")) { ControllerManagementView() } }
        .sheet(isPresented: $model.showSteamStorage) { SteamStorageView().environmentObject(model) }
        .sheet(item: $model.pendingSteamInstall) { target in SteamStorageView(target: target).environmentObject(model) }
    }

    private func select(_ next: CompanionDestination) {
        guard next != destination else { return }
        if hasUnsavedGameSettings { pendingDestination = next } else { destination = next }
    }

    private func navigation(_ title: String, icon: String, target: CompanionDestination) -> some View {
        Button { select(target) } label: {
            Label(title, systemImage: icon).font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .foregroundStyle(destination == target ? .white : IndiePalette.secondaryText)
                .background(destination == target ? IndiePalette.surfaceStrong : .clear, in: RoundedRectangle(cornerRadius: 3))
        }
    }
}

private struct WindowPlacementReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = WindowPlacementNSView()
        view.onWindow = { window in
            guard !context.coordinator.didPlace else { return }
            context.coordinator.didPlace = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let screen = NSScreen.main else { return }
                let visible = screen.visibleFrame
                let targetHeight = min(946, visible.height - 60)
                let size = NSSize(
                    width: min(1500, visible.width - 80, targetHeight * 1.585),
                    height: targetHeight
                )
                let origin = NSPoint(
                    x: visible.midX - size.width / 2,
                    y: visible.midY - size.height / 2
                )
                window.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var didPlace = false }
}

private final class WindowPlacementNSView: NSView {
    var onWindow: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { DispatchQueue.main.async { [weak self] in self?.onWindow?(window) } }
    }
}

struct PortlaneMark: View {
    var size: CGFloat = 21
    private var image: NSImage? {
        PackagedResources.bundle(named: "MacGamingUncle_MacGamingUncleApp", development: Bundle.module)?
            .url(forResource: "portlane-mark", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "play.circle.fill").foregroundStyle(IndiePalette.blue)
            }
        }
        .frame(width: size, height: size).accessibilityHidden(true)
    }
}

private struct IndieBackground: View {
    var body: some View {
        ZStack {
            IndiePalette.canvas
            RadialGradient(colors: [IndiePalette.primary.opacity(0.18), .clear], center: UnitPoint(x: 0.64, y: 0.34), startRadius: 20, endRadius: 520)
            RadialGradient(colors: [IndiePalette.blue.opacity(0.12), .clear], center: UnitPoint(x: 0.88, y: 0.72), startRadius: 30, endRadius: 470)
        }
        .ignoresSafeArea()
    }
}

private struct SetupHomeView: View {
    @EnvironmentObject private var model: MacGamingUncleAppModel
    let openLibrary: () -> Void
    let showAdvanced: () -> Void

    private var stage: SetupStage { model.setupStage }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                SetupProgressHeader(stage: stage).padding(.top, 26)
                Spacer(minLength: 50)

                VStack(spacing: 20) {
                    Text(L("让 Windows 游戏在 Mac 上运行"))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .tracking(-0.6)
                        .multilineTextAlignment(.center)

                    Image(systemName: stageIcon)
                        .font(.system(size: 31, weight: .medium))
                        .foregroundStyle(LinearGradient(colors: [Color.white, Color(red: 0.66, green: 0.53, blue: 1)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 66, height: 66)
                        .background(IndiePalette.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(IndiePalette.primary.opacity(0.30)))
                        .shadow(color: IndiePalette.primary.opacity(0.26), radius: 22)
                        .padding(.top, 12)

                    Text(stageTitle).font(.system(size: 25, weight: .semibold, design: .rounded))

                    Text(stageDescription)
                        .font(.system(size: 15.5))
                        .foregroundStyle(IndiePalette.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(5)
                        .frame(maxWidth: 610)

                    readinessPill.padding(.top, 4)

                    Button(action: primaryAction) {
                        HStack(spacing: 12) {
                            if model.isWorking { ProgressView().controlSize(.small).tint(.white) }
                            else { Image(systemName: primaryIcon).font(.system(size: 16, weight: .bold)) }
                            Text(primaryTitle).font(.system(size: 17, weight: .semibold))
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.right").font(.system(size: 15, weight: .bold))
                        }
                        .padding(.horizontal, 22)
                        .frame(width: 360, height: 58)
                    }
                    .buttonStyle(IndiePrimaryButtonStyle())
                    .disabled(model.isWorking || systemBlocked)
                    .accessibilityHint(primaryHint)
                    .padding(.top, 12)

                    HStack(spacing: 6) {
                        Image(systemName: model.isWorking ? "arrow.down.circle" : "clock")
                        Text(model.isWorking ? model.status : durationText)
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(IndiePalette.secondaryText)
                    .frame(minHeight: 20)
                }

                Spacer(minLength: 54)
                NextStepStrip(stage: stage, showAdvanced: showAdvanced).padding(.bottom, 28)
            }
            .frame(maxWidth: 1040, minHeight: 690)
            .padding(.horizontal, 36)
            .frame(maxWidth: .infinity)
        }
    }

    private var readinessPill: some View {
        HStack(spacing: 9) {
            Image(systemName: systemBlocked ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(systemBlocked ? .orange : IndiePalette.green)
            Text(readinessText)
        }
        .font(.system(size: 13.5, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(IndiePalette.surface, in: Capsule())
        .overlay(Capsule().stroke(IndiePalette.border))
    }

    private var systemBlocked: Bool { model.systemReport.map { !$0.isSupported } ?? false }
    private var readinessText: String {
        if systemBlocked { return L("环境检查未通过，请查看高级设置") }
        return L("已检测到 \(model.systemReport?.chip ?? "Apple Silicon") · Rosetta 2 已就绪")
    }
    private var stageIcon: String {
        switch stage { case .environment: "shield.checkered"; case .steam: "arrow.down.app"; case .game: "gamecontroller"; case .ready: "checkmark.seal" }
    }
    private var stageTitle: String {
        switch stage { case .environment: L("准备游戏环境"); case .steam: L("安装 Windows 版 Steam"); case .game: L("从 Steam 安装第一个游戏"); case .ready: L("你的游戏已经准备好") }
    }
    private var stageDescription: String {
        switch stage {
        case .environment: L("Portlane 会自动下载并验证运行游戏所需的开源兼容组件。\n不会安装 Windows，也不会修改系统安全设置。")
        case .steam: L("环境已经准备完成。接下来 Portlane 会从 Valve 官方地址下载并打开 Steam 安装程序，你只需完成安装。")
        case .game: L("打开 Steam，登录你的账户，在“游戏库”中选择一款 Windows 游戏并点击“安装”。安装完成后回到 Portlane 扫描游戏。")
        case .ready: L("已发现 \(model.steamGames.count) 个 Steam 游戏。你可以从游戏库直接启动，Portlane 会自动选择合适的图形兼容方案。")
        }
    }
    private var primaryTitle: String {
        switch stage { case .environment: L("一键准备环境"); case .steam: L("安装 Steam"); case .game: L("打开 Steam 安装游戏"); case .ready: L("前往游戏库") }
    }
    private var primaryIcon: String {
        switch stage { case .environment: "sparkles"; case .steam: "arrow.down.app.fill"; case .game: "play.rectangle.fill"; case .ready: "gamecontroller.fill" }
    }
    private var primaryHint: String {
        switch stage {
        case .environment: L("下载并验证 Wine 游戏运行环境")
        case .steam: L("从 Valve 官方地址下载并打开 Steam 安装程序")
        case .game: L("打开 Windows 版 Steam，以便登录并安装游戏")
        case .ready: L("查看已经安装的 Steam 和本地游戏")
        }
    }
    private var durationText: String {
        switch stage {
        case .environment: L("首次下载约 190 MB · 大约 3–8 分钟")
        case .steam: L("下载后会出现 Steam 安装窗口")
        case .game: L("游戏安装由 Steam 完成")
        case .ready: L("环境、Steam 与游戏均已就绪")
        }
    }
    private func primaryAction() {
        switch stage {
        case .environment: Task { await model.prepareEnvironment() }
        case .steam: Task { await model.installSteam() }
        case .game: Task { await model.launchSteam() }
        case .ready: openLibrary()
        }
    }
}

private struct SetupProgressHeader: View {
    let stage: SetupStage
    var body: some View {
        HStack(spacing: 14) {
            progressItem(number: 1, title: L("准备环境"))
            connector(after: 1)
            progressItem(number: 2, title: L("安装 Steam"))
            connector(after: 2)
            progressItem(number: 3, title: L("选择游戏"))
        }
        .frame(maxWidth: 700)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("设置进度，第 \(min(stage.rawValue, 3)) 步，共 3 步"))
    }
    private func progressItem(number: Int, title: String) -> some View {
        let current = stage.rawValue == number
        let complete = stage.rawValue > number
        return HStack(spacing: 10) {
            ZStack {
                Circle().fill(current ? IndiePalette.primary : complete ? IndiePalette.green.opacity(0.15) : IndiePalette.surface)
                Circle().stroke(current ? Color.white.opacity(0.55) : complete ? IndiePalette.green.opacity(0.55) : IndiePalette.border, lineWidth: 1.2)
                if complete { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(IndiePalette.green) }
                else { Text("\(number)").font(.system(size: 13, weight: .semibold)).foregroundStyle(current ? .white : IndiePalette.secondaryText) }
            }
            .frame(width: 36, height: 36)
            .shadow(color: current ? IndiePalette.primary.opacity(0.55) : .clear, radius: 12)
            Text(title).font(.system(size: 14, weight: current ? .semibold : .medium)).foregroundStyle(current || complete ? Color.white : IndiePalette.secondaryText)
        }
    }
    private func connector(after number: Int) -> some View {
        Rectangle().fill(stage.rawValue > number ? IndiePalette.primary.opacity(0.75) : IndiePalette.border).frame(maxWidth: 86, maxHeight: 1)
    }
}

private struct NextStepStrip: View {
    let stage: SetupStage
    let showAdvanced: () -> Void
    var body: some View {
        HStack(spacing: 18) {
            Group {
                if stage == .ready {
                    Image(systemName: "play.circle")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(LinearGradient(colors: [Color.white, IndiePalette.blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                } else {
                    SteamLogoAsset()
                }
            }
            .frame(width: 104, height: 58)
            .background(Color.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(detail).font(.system(size: 13.5)).foregroundStyle(IndiePalette.secondaryText)
            }
            Spacer()
            Button(L("了解详情")) { showAdvanced() }.buttonStyle(.bordered)
            Button(L("高级设置"), systemImage: "chevron.right") { showAdvanced() }.buttonStyle(.plain).foregroundStyle(IndiePalette.secondaryText)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(IndiePalette.surface, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(IndiePalette.border))
    }
    private var title: String {
        switch stage { case .environment: L("接下来：安装并登录 Steam"); case .steam: L("安装完成后：登录 Steam"); case .game: L("在 Steam 中选择并安装游戏"); case .ready: L("现在可以开始游戏") }
    }
    private var detail: String {
        switch stage {
        case .environment: L("环境准备完成后，Portlane 将为你打开官方 Steam 安装程序。")
        case .steam: L("Portlane 不会读取或保存你的 Steam 账户和密码。")
        case .game: L("安装完成后返回 Portlane，游戏会自动出现在游戏库。")
        case .ready: L("需要更换图形兼容方案时，可在高级设置中调整。")
        }
    }
}

private struct SteamLogoAsset: View {
    var body: some View {
        if let url = PackagedResources.bundle(named: "MacGamingUncle_MacGamingUncleApp", development: Bundle.module)?
            .url(forResource: "steam-logo", withExtension: "svg"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFit().padding(.horizontal, 16).accessibilityLabel("Steam")
        } else {
            Image(systemName: "arrow.down.app").foregroundStyle(IndiePalette.blue).accessibilityLabel("Steam")
        }
    }
}

private struct IndiePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                LinearGradient(
                    colors: configuration.isPressed ? [IndiePalette.primary.opacity(0.78), IndiePalette.blue.opacity(0.78)] : [Color(red: 0.56, green: 0.29, blue: 1.0), Color(red: 0.10, green: 0.54, blue: 1.0)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ), in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.38), lineWidth: 1))
            .shadow(color: IndiePalette.primary.opacity(configuration.isPressed ? 0.22 : 0.44), radius: configuration.isPressed ? 12 : 22, y: 7)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct LibraryView: View {
    @EnvironmentObject private var model: MacGamingUncleAppModel
    let returnToStart: () -> Void
    @State private var settingsTarget: GameSettingsTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L("游戏库")).font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(L("从 Steam 安装游戏，或直接导入本地 Windows 程序。")).foregroundStyle(IndiePalette.secondaryText)
                    SteamSessionIndicator(manager: model.steamSessionManager)
                }
                Spacer()
                Button(L("扫描 Steam"), systemImage: "arrow.clockwise") { model.rescanSteam() }.disabled(model.steamExecutable == nil || model.isWorking)
                Button(L("导入本地游戏"), systemImage: "plus") { chooseExecutable() }.buttonStyle(.borderedProminent)
            }
            if model.isWorking {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(model.status) }.font(.system(size: 13.5)).foregroundStyle(IndiePalette.secondaryText)
            }
            if model.games.isEmpty && model.steamGames.isEmpty { emptyState }
            else {
                ScrollView {
                    VStack(spacing: 20) {
                        if !model.steamGames.isEmpty { steamSection }
                        if !model.games.isEmpty { localSection }
                    }
                }
            }
        }
        .padding(34)
        .sheet(item: $settingsTarget) { target in
            GameSettingsView(target: target)
                .environmentObject(model)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "gamecontroller").font(.system(size: 42, weight: .light)).foregroundStyle(IndiePalette.primary)
            Text(L("还没有安装游戏")).font(.system(size: 22, weight: .semibold))
            Text(emptyDescription).multilineTextAlignment(.center).foregroundStyle(IndiePalette.secondaryText)
            Button(emptyButtonTitle, systemImage: emptyButtonIcon) { emptyAction() }.buttonStyle(.borderedProminent).controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var steamSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Steam 游戏")).font(.system(size: 16, weight: .semibold)).padding(18)
            Divider().overlay(IndiePalette.border)
            ForEach(model.steamGames) { game in
                HStack(spacing: 14) {
                    Image(systemName: "gamecontroller.fill").foregroundStyle(IndiePalette.primary).frame(width: 42, height: 42).background(IndiePalette.surface, in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(game.name).font(.system(size: 15, weight: .semibold))
                        Text(L("Steam 游戏 · 版本 \(game.buildID ?? L("未知")) · \(model.d3dMetalRuntimeAvailable ? "GPTK 4 / D3DMetal" : L("需要 GPTK 4"))\(hasCustomSettings(model.configuration(for: game).id) ? L(" · 已自定义") : "")"))
                            .font(.system(size: 12.5)).foregroundStyle(IndiePalette.secondaryText)
                    }
                    Spacer()
                    if model.d3dMetalRuntimeAvailable {
                        Button { Task { await model.launchSteamGame(game) } } label: {
                            HStack(spacing: 7) { PortlaneMark(); Text(L("智能启动")) }
                        }
                            .disabled(model.isWorking)
                    } else {
                        Button(L("升级 GPTK 4"), systemImage: "arrow.down.circle") {
                            model.startGPTKSetup()
                        }
                    }
                    Button(L("设置"), systemImage: "slider.horizontal.3") { openSettings(for: game) }
                    .help(L("配置 \(game.name)"))
                    Menu {
                        Button(L("游戏设置"), systemImage: "slider.horizontal.3") { openSettings(for: game) }
                        Button(L("通过 Steam 启动"), systemImage: "gamecontroller") {
                            Task { await model.launchSteam(appID: game.appID) }
                        }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(model.isWorking)
                }
                .padding(.horizontal, 18).padding(.vertical, 13)
                if game.id != model.steamGames.last?.id { Divider().overlay(IndiePalette.border).padding(.leading, 72) }
            }
        }
        .background(IndiePalette.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(IndiePalette.border))
    }

    private var localSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("本地游戏")).font(.system(size: 16, weight: .semibold)).padding(18)
            Divider().overlay(IndiePalette.border)
            ForEach(model.games) { game in
                HStack(spacing: 14) {
                    Image(systemName: "app.dashed").foregroundStyle(IndiePalette.blue).frame(width: 42, height: 42).background(IndiePalette.surface, in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(game.displayName).font(.system(size: 15, weight: .semibold))
                        Text("\(architectureName(game.analysis.architecture)) · \(directXName(game.analysis.directX))\(hasCustomSettings(model.configuration(for: game).id) ? L(" · 已自定义") : "")")
                            .font(.system(size: 12.5)).foregroundStyle(IndiePalette.secondaryText)
                    }
                    Spacer()
                    if game.analysis.antiCheat == .kernel { Label(L("反作弊不兼容"), systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
                    else {
                        Button { Task { await model.play(game) } } label: {
                            HStack(spacing: 7) { PortlaneMark(); Text(L("运行")) }
                        }.disabled(model.isWorking)
                    }
                    Button(L("设置"), systemImage: "slider.horizontal.3") { openSettings(for: game) }
                    .help(L("配置 \(game.displayName)"))
                }
                .padding(.horizontal, 18).padding(.vertical, 13)
            }
        }
        .background(IndiePalette.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(IndiePalette.border))
    }

    private var emptyDescription: String {
        if !model.environmentReady { return L("请先回到“开始”页面，一键准备游戏环境。") }
        if model.steamExecutable == nil { return L("环境已经就绪，下一步安装 Windows 版 Steam。") }
        return L("打开 Steam 登录后，选择游戏并点击安装。完成后回到这里扫描游戏库。")
    }
    private var emptyButtonTitle: String {
        if !model.environmentReady { return L("返回开始") }
        if model.steamExecutable == nil { return L("安装 Steam") }
        return L("打开 Steam 安装游戏")
    }
    private var emptyButtonIcon: String {
        if !model.environmentReady { return "arrow.left" }
        if model.steamExecutable == nil { return "arrow.down.app" }
        return "play.rectangle"
    }
    private func emptyAction() {
        if !model.environmentReady { returnToStart() }
        else if model.steamExecutable == nil { Task { await model.installSteam() } }
        else { Task { await model.launchSteam() } }
    }
    private func chooseExecutable() {
        if let url = SteamFileDialog.choose(title: L("导入本地 EXE"), extensions: ["exe"]) { Task { await model.importExecutable(url) } }
    }
    private func architectureName(_ architecture: CPUArchitecture) -> String {
        switch architecture { case .i386: L("32 位 Intel"); case .x86_64: L("64 位 Intel"); case .arm64: L("64 位 ARM"); case .arm64ec: "ARM64EC"; case .unknown: L("未知架构") }
    }
    private func directXName(_ version: DirectXVersion) -> String { version == .none ? L("未检测到 DirectX") : version.rawValue.uppercased() }
    private func hasCustomSettings(_ id: String) -> Bool { model.gameConfigurations[id]?.isCustomized == true }
    private func openSettings(for game: SteamGame) {
        let configuration = model.configuration(for: game)
        settingsTarget = .init(
            id: configuration.id,
            name: game.name,
            detail: "Steam AppID \(game.appID)",
            configuration: configuration
        )
    }
    private func openSettings(for game: GameRecord) {
        let configuration = model.configuration(for: game)
        settingsTarget = .init(
            id: configuration.id,
            name: game.displayName,
            detail: "\(architectureName(game.analysis.architecture)) · \(directXName(game.analysis.directX))",
            configuration: configuration
        )
    }
}

struct SteamSessionIndicator: View {
    @EnvironmentObject private var model: MacGamingUncleAppModel
    @ObservedObject var manager: SteamSessionManager

    var body: some View {
        if model.steamAuthenticationRequired {
            Label(L("Steam 未联机"), systemImage: "wifi.slash")
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.orange)
        } else if manager.state == .running {
            Label(
                manager.reuseCount > 0 ? L("Steam 已保持登录 · 已快速复用 \(manager.reuseCount) 次") : L("Steam 已保持登录"),
                systemImage: "bolt.circle.fill"
            )
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(IndiePalette.green)
        }
    }
}

struct AdvancedSettingsView: View {
    @EnvironmentObject private var model: MacGamingUncleAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var section = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("高级设置")).font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(L("管理兼容组件与查看诊断信息")).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("完成")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(24)
            Picker("", selection: $section) {
                Text(L("运行环境")).tag(0); Text(L("环境诊断")).tag(1); Text(L("偏好设置")).tag(2)
            }
            .pickerStyle(.segmented).padding(.horizontal, 24).padding(.bottom, 18)
            Divider()
            Group {
                if section == 0 { RuntimeSettingsContent() }
                else if section == 1 { DiagnosticsContent() }
                else { PreferencesContent() }
            }
        }
        .preferredColorScheme(.dark)
        .background(IndiePalette.canvas)
    }
}

struct RuntimeSettingsContent: View {
    @EnvironmentObject private var model: MacGamingUncleAppModel
    @State private var pendingWineDeletion: LocalWineRuntime?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                advancedSection(title: L("Wine 运行环境"), detail: L("Portlane 自行从 LGPL 源码构建 Wine 11 新 WoW64 运行时；不封装或分发 CrossOver 应用。")) {
                    ForEach(model.wineRuntimes) { runtime in
                        wineRow(runtime)
                    }
                    Text(L("当前使用的版本用于下一次启动；切换前请先退出游戏和 Windows Steam。删除会移到废纸篓，保留游戏和容器。"))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(L("自动安装最新版本")) { Task { await model.prepareEnvironment() } }.buttonStyle(.borderedProminent)
                        Button(L("导入本地 Wine")) { chooseWine() }
                    }
                }
                advancedSection(title: "Apple D3DMetal", detail: L("Apple 官方 GPTK 中的 DirectX 11/12 图形转换组件，适合现代 DX12 游戏。")) {
                    ForEach(model.d3dMetal, id: \.root) { component in componentRow(name: "D3DMetal \(component.version)", status: L("Apple 签名已验证")) }
                    if let version = model.gptkRuntimeVersion {
                        componentRow(name: L("完整 GPTK 运行时 \(version)"), status: model.gptkNeedsUpdate ? L("需要升级到 GPTK 4") : L("可用于游戏"))
                    }
                    HStack {
                        if model.isGPTKSetupRunning {
                            Button(L("取消等待"), role: .cancel) { model.cancelGPTKSetup() }
                        } else {
                            Button(L("一键安装 GPTK 4")) { model.startGPTKSetup() }.buttonStyle(.borderedProminent)
                        }
                        Button(L("导入 GPTK 镜像")) { chooseGPTK() }.buttonStyle(.borderedProminent)
                    }
                    if model.isGPTKSetupRunning {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(model.status) }
                            .font(.system(size: 12.5)).foregroundStyle(IndiePalette.secondaryText)
                    }
                }
                advancedSection(title: L("开源图形组件"), detail: L("DXMT 用于 DirectX 10/11；DXVK 与 VKD3D 作为兼容回退或实验路径。")) {
                    ForEach(model.rendererOverlays) { overlay in componentRow(name: "\(overlay.kind.rawValue.uppercased()) \(overlay.version)", status: L("已导入")) }
                    HStack {
                        Button(L("导入 DXMT")) { chooseRenderer(.dxmt) }; Button(L("导入 DXVK")) { chooseRenderer(.dxvk) }; Button(L("导入 VKD3D")) { chooseRenderer(.vkd3d) }
                    }
                }
            }
            .padding(24)
        }
        .task {
            while !Task.isCancelled {
                model.refreshWineUsage()
                do { try await Task.sleep(for: .seconds(2)) }
                catch { break }
            }
        }
        .steamDialog(L("删除 Wine 版本？"), isPresented: Binding(
            get: { pendingWineDeletion != nil },
            set: { if !$0 { pendingWineDeletion = nil } }
        )) {
            Button(L("取消"), role: .cancel) { pendingWineDeletion = nil }
            Button(L("删除"), role: .destructive) {
                if let runtime = pendingWineDeletion {
                    Task { await model.deleteWineRuntime(runtime) }
                }
                pendingWineDeletion = nil
            }
        } message: {
            Text(L("将 \(AppBrand.runtimeDisplayName(pendingWineDeletion?.manifest.displayName ?? "")) 移到废纸篓。游戏和容器不会被删除。"))
        }
    }
    private func advancedSection<Content: View>(title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 17, weight: .semibold)); Text(detail).font(.system(size: 13.5)).foregroundStyle(IndiePalette.secondaryText); content()
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(18)
        .background(IndiePalette.panel, in: RoundedRectangle(cornerRadius: 3)).overlay(RoundedRectangle(cornerRadius: 3).stroke(IndiePalette.border))
    }
    private func wineRow(_ runtime: LocalWineRuntime) -> some View {
        let selected = model.gamingWineRuntime?.id == runtime.id
        let running = model.runningWineRuntimeIDs.contains(runtime.id)
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppBrand.runtimeDisplayName(runtime.manifest.displayName)).font(.system(size: 13.5, weight: .medium))
                Text(runtime.manifest.version.description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if running { Text(L("正在运行")).foregroundStyle(IndiePalette.green) }
            if selected { Label(L("当前使用"), systemImage: "checkmark.circle.fill").foregroundStyle(IndiePalette.green) }
            if !selected && runtime.manifest.id == CommunityIndieWineBootstrapper.runtimeID {
                Button(L("使用此版本")) { Task { await model.selectWineRuntime(runtime) } }
                    .disabled(model.isWorking || !model.runningWineRuntimeIDs.isEmpty)
            }
            Button(L("删除"), role: .destructive) { pendingWineDeletion = runtime }
                .disabled(model.isWorking || selected || running)
        }.font(.system(size: 12.5))
    }

    private func componentRow(name: String, status: String) -> some View {
        HStack { Image(systemName: "checkmark.circle.fill").foregroundStyle(IndiePalette.green); Text(name).font(.system(size: 13.5, weight: .medium)); Spacer(); Text(status).font(.system(size: 12.5)).foregroundStyle(IndiePalette.secondaryText) }
    }
    private func chooseGPTK() {
        if let url = SteamFileDialog.choose(title: L("导入 GPTK 镜像"), extensions: ["dmg"], directories: true) { Task { await model.importGPTK(url) } }
    }
    private func chooseWine() {
        if let url = SteamFileDialog.choose(title: L("导入"), directories: true) { Task { await model.importWine(url) } }
    }
    private func chooseRenderer(_ kind: RendererKind) {
        if let url = SteamFileDialog.choose(title: L("导入"), directories: true) { Task { await model.importRenderer(kind, from: url) } }
    }
}

struct DiagnosticsContent: View {
    @EnvironmentObject private var model: MacGamingUncleAppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(L("这台 Mac")).font(.system(size: 18, weight: .semibold)); Spacer(); Button(L("重新检查"), systemImage: "arrow.clockwise") { Task { await model.refresh() } } }.padding(24)
            ScrollView {
              LazyVStack(spacing: 10) {
               ForEach(model.systemReport?.items ?? []) { item in
                HStack(spacing: 12) {
                    Image(systemName: item.severity == .pass ? "checkmark.circle.fill" : item.severity == .warning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill").foregroundStyle(item.severity == .pass ? IndiePalette.green : item.severity == .warning ? .orange : .red)
                    VStack(alignment: .leading, spacing: 4) { Text(item.title).font(.system(size: 14, weight: .semibold)); Text(item.detail).font(.system(size: 13)).foregroundStyle(IndiePalette.secondaryText) }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(IndiePalette.panel, in: RoundedRectangle(cornerRadius: 3))
               }
              }.padding(.horizontal, 24).padding(.bottom, 24)
            }
        }
    }
}

struct PreferencesContent: View {
    @AppStorage("metalHUD") private var metalHUD = false
    @AppStorage("metalFX") private var metalFX = false
    @AppStorage("metal4") private var metal4 = true
    var body: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
           SteamSettingsSection {
            LanguagePicker()
           }
           SteamSettingsSection(title: L("图形")) {
            Toggle(L("启动游戏时显示 Apple Metal HUD"), isOn: $metalHUD)
            Text(L("D3DMetal 游戏会在同一个 Portlane Wine 11 + Steam 会话中显示 Apple 官方 FPS、GPU 时间、内存和帧间隔；非 D3DMetal 兼容回退不会显示该 HUD。"))
                .font(.system(size: 12.5)).foregroundStyle(IndiePalette.secondaryText)
            Toggle(L("优先使用 Metal 4"), isOn: $metal4)
            Text(L("GPTK 4 会在支持的 Apple GPU 与 macOS 上使用新的 Metal 4 提交路径；遇到个别游戏异常时可关闭并回退。"))
                .font(.system(size: 12.5)).foregroundStyle(IndiePalette.secondaryText)
            Toggle(L("使用 MetalFX 兼容游戏的 DLSS"), isOn: $metalFX)
            Text(L("需要 GPTK 4/D3DMetal，且仍需在游戏画面设置中开启 DLSS。Apple GPU 实际执行的是 MetalFX。"))
                .font(.system(size: 12.5)).foregroundStyle(IndiePalette.secondaryText)
           }
            Text(L("Portlane 不收集遥测数据。兼容配方来自可审计的 Git 仓库。")).font(.system(size: 12.5)).foregroundStyle(IndiePalette.secondaryText)
          }.padding(24)
        }
        .steamSurface()
    }
}

struct SettingsView: View {
    var body: some View { PreferencesContent().frame(width: 620, height: 560) }
}

private extension UTType {
    static let exe = UTType(filenameExtension: "exe") ?? .data
}
