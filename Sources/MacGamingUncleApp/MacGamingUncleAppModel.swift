import AppKit
import Foundation
import IndieCatalog
import IndieCore
import IndieRuntime
import Metal

@MainActor
final class MacGamingUncleAppModel: ObservableObject {
    @Published var systemReport: SystemReport?
    @Published var games: [GameRecord] = []
    @Published var steamGames: [SteamGame] = []
    @Published var steamDownloads: [SteamGame] = []
    @Published var steamLibraries: [SteamLibraryLocation] = []
    @Published var showSteamStorage = false
    @Published var pendingSteamInstall: SteamInstallTarget?
    @Published private(set) var isManagingSteamStorage = false
    @Published private(set) var steamStorageError: String?
    var preferredSteamLibraryID: String? { UserDefaults.standard.string(forKey:"preferredSteamLibraryID") }
    private var didAutomaticallyOpenSteam = false
    @Published private(set) var isOpeningSteamClient = false
    @Published var steamClientNotice: String?
    @Published var steamInstallationRequests: [UInt64: SteamInstallationRequestState] = [:]
    @Published private(set) var steamBridgeDownloads: [UInt64: SteamBridgeDownload] = [:]
    @Published private(set) var steamAuthenticationRequired = false
    @Published private(set) var uninstallingSteamAppIDs: Set<UInt64> = []
    @Published private(set) var steamDownloadSpeeds: [UInt64: Double] = [:]
    private var downloadByteSamples: [UInt64: (UInt64, Date)] = [:]
    private var steamDownloadBridge: SteamDownloadBridge?
    private var steamBridgeRoot: URL?
    private var steamBridgePoll: Task<Void, Never>?
    private var submittingSteamInstall = false
    private var backgroundSteamWindowTask: Task<Void, Never>?
    private var steamInstallSubmittedAt: [UInt64: Date] = [:]
    @Published var gameLaunchStates: [UInt64: GameLaunchState] = [:]
    @Published private(set) var gameLaunchReports: [UInt64: GameLaunchReport] = [:]
    private var gameLaunchMonitors: [UInt64: Task<Void, Never>] = [:]
    @Published private(set) var steamLaunchRelayActive = false
    @Published private(set) var steamLaunchRelayDetail = ""
    private var steamLaunchRelayTask: Task<Void, Never>?
    private var steamPlayRequestTask: Task<Void, Never>?
    private var pendingSteamPlayRequests: [UInt64] = []

    func startSteamLaunchRelay() {
        guard steamLaunchRelayTask == nil else { return }
        steamLaunchRelayTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let bridge = self.downloadBridge(), !self.onboardingBusy {
                    do {
                        let snapshot = try await bridge.takeGameLaunchRequests(appIDs: (self.steamGames + self.steamDownloads).map(\.appID))
                        self.steamLaunchRelayActive = snapshot.active
                        self.steamLaunchRelayDetail = ""
                        for appID in snapshot.appIDs where !self.pendingSteamPlayRequests.contains(appID) {
                            self.pendingSteamPlayRequests.append(appID)
                        }
                        if self.steamPlayRequestTask == nil, !self.isWorking, !self.isOpeningSteamClient, let appID = self.pendingSteamPlayRequests.first {
                            self.pendingSteamPlayRequests.removeFirst()
                            self.steamPlayRequestTask = Task {
                                defer { self.steamPlayRequestTask = nil }
                                if let game = (self.steamGames + self.steamDownloads).first(where: { $0.appID == appID }) {
                                    await self.launchSteamGame(game, fromSteamPlay: true)
                                }
                                await bridge.completeGameLaunchRequest(appID: appID)
                            }
                        }
                    } catch { self.steamLaunchRelayActive = false; self.steamLaunchRelayDetail = error.localizedDescription }
                } else { self.steamLaunchRelayActive = false }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    @Published var steamAccountGames: [SteamAccountGame] = []
    @Published var steamActivities: [UInt64: SteamGameActivity] = [:]
    @Published var steamStoreCatalog: SteamStoreCatalog?
    @Published private(set) var steamSearchState = SteamStoreSearchState()
    var steamStoreSearchResults: [SteamStoreItem] { steamSearchState.results }
    @Published var steamStoreSelectedAppID: UInt64?
    @Published var isSteamStoreLoading = false
    @Published var steamStoreError: String?
    var isSteamSearchLoading: Bool { steamSearchState.isLoading }
    var steamSearchQuery: String { steamSearchState.query }
    var steamSearchCompleted: Bool { steamSearchState.completed }
    var steamSearchError: String? { steamSearchState.error }
    private var steamSearchTask: Task<[SteamStoreItem], Error>?
    private let steamLibraryReader = SteamLibraryReader()
    private var steamMetadataRetry = SteamMetadataRetryPolicy()
    private var steamMetadataCacheLoaded = false
    private var steamMetadataCacheLoadTask: Task<[UInt64: SteamStoreMetadataService.Metadata], Never>?
    @Published private(set) var isSteamMetadataLoading = false
    @Published var requestedDestination: String?
    @Published var bottles: [BottleRecord] = []
    @Published var d3dMetal: [ImportedD3DMetal] = []
    @Published var wineRuntimes: [LocalWineRuntime] = []
    @Published private(set) var selectedWineRuntimeID = UserDefaults.standard.string(forKey: "selectedWineRuntimeID")
    @Published private(set) var runningWineRuntimeIDs: Set<String> = []
    @Published var rendererOverlays: [RendererOverlay] = []
    @Published var gameConfigurations: [String: GameConfiguration] = [:]
    @Published var isWorking = false
    @Published var isGPTKSetupRunning = false
    @Published var status = ""
    @Published var lastError: String?
    @Published var onboardingStage = FirstRunStage.checking
    @Published var onboardingBusy = false
    @Published var onboardingError: String?
    @Published var onboardingMessage = L("正在检查这台 Mac 的运行环境…")
    private var onboardingTask: Task<Void, Never>?

    let paths = IndiePaths.userDefault
    let controllerManager: ControllerManager
    let steamSessionManager: SteamSessionManager
    private let store: StateStore
    private let probe = SystemProbe()
    private lazy var importer = GPTKImporter(paths: paths)
    private lazy var wineImporter = LocalWineImporter(paths: paths)
    private lazy var overlayImporter = RendererOverlayImporter(paths: paths)
    private lazy var communityGamingWine = CommunityIndieWineBootstrapper(paths: paths)
    private lazy var communityDXMT = CommunityDXMTBootstrapper(paths: paths)
    private var recipeRepository = RecipeRepository(recipes: [])
    private var gptkSetupTask: Task<Void, Never>?
    private var steamMetadataTask: Task<Void, Never>?
    private var steamMetadataCache: [UInt64: SteamStoreMetadataService.Metadata] = [:]
    private var steamStoreLoadedAt: Date?

    var environmentReady: Bool {
        systemReport?.isSupported == true && gamingWineRuntime != nil
    }

    private var preferredGPTKRuntime: AppleGPTKRuntime? {
        AppleGPTKRuntime.discover(importedComponents: d3dMetal) ?? AppleGPTKRuntime.discover()
    }
    private var preferredD3DMetal: ImportedD3DMetal? {
        d3dMetal.first { $0.rendererRoot != nil }
    }
    var gamingWineRuntime: LocalWineRuntime? {
        LocalWineImporter.selectedGamingRuntime(in: wineRuntimes, preferredID: selectedWineRuntimeID)
    }

    func refreshWineUsage() {
        runningWineRuntimeIDs = Set(wineRuntimes.filter {
            WineProcessReaper.hasRunningProcesses(runtimeRoot: $0.root)
        }.map(\.id))
    }

    func selectWineRuntime(_ runtime: LocalWineRuntime) async {
        await perform(L("正在切换 Wine…")) {
            self.refreshWineUsage()
            guard self.runningWineRuntimeIDs.isEmpty else {
                throw IndieError.invalidData(L("请先退出游戏和 Windows Steam，再切换 Wine"))
            }
            guard self.wineRuntimes.contains(runtime),
                  runtime.manifest.id == CommunityIndieWineBootstrapper.runtimeID else {
                throw IndieError.unsupported(L("游戏引擎只能选择 Portlane Wine 版本"))
            }
            self.selectedWineRuntimeID = runtime.id
            UserDefaults.standard.set(runtime.id, forKey: "selectedWineRuntimeID")
            self.steamSessionManager.didStop()
            self.status = L("Wine 已切换为 \(runtime.manifest.version)")
        }
    }

    func deleteWineRuntime(_ runtime: LocalWineRuntime) async {
        await perform(L("正在删除 Wine…")) {
            guard runtime.id != self.gamingWineRuntime?.id else {
                throw IndieError.invalidData(L("请先切换到其他 Wine，再删除当前使用的版本"))
            }
            try await self.wineImporter.removeRuntime(runtime)
            self.wineRuntimes = await self.wineImporter.installed()
            self.refreshWineUsage()
            self.status = L("Wine 已移到废纸篓，游戏和容器已保留")
        }
    }
    var gptkRuntimeVersion: String? { preferredD3DMetal?.version ?? preferredGPTKRuntime?.version }
    var d3dMetalRuntimeAvailable: Bool {
        guard let version = gptkRuntimeVersion else { return false }
        return Self.majorVersion(version) >= 4 && preferredD3DMetal?.rendererRoot != nil && gamingWineRuntime != nil
    }
    var gptkNeedsUpdate: Bool {
        guard let version = gptkRuntimeVersion else { return true }
        return Self.majorVersion(version) < 4
    }

    var steamBottle: BottleRecord? { bottles.first { $0.name == "Steam" } }

    var availableRendererKinds: Set<RendererKind> {
        var result: Set<RendererKind> = [.wineD3D]
        if d3dMetalRuntimeAvailable { result.insert(.d3dMetal) }
        result.formUnion(rendererOverlays.map(\.kind))
        return result
    }

    var steamExecutable: URL? {
        guard let bottle = steamBottle else { return nil }
        let candidates = [
            bottle.root.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe"),
            bottle.root.appendingPathComponent("drive_c/Program Files/Steam/steam.exe"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    var setupStage: SetupStage {
        SetupFlow.stage(
            environmentReady: environmentReady,
            steamInstalled: steamExecutable != nil,
            installedGameCount: steamGames.count
        )
    }

    init() {
        store = StateStore(databaseURL: paths.database)
        controllerManager = ControllerManager()
        steamSessionManager = SteamSessionManager()
        onboardingTask = Task {
            await refresh()
            await runOnboarding()
        }
    }

    var onboardingGraphicsReady: Bool { d3dMetalRuntimeAvailable }
    var onboardingWineReady: Bool { gamingWineRuntime != nil }
    var onboardingDXMTReady: Bool { rendererOverlays.contains { $0.kind == .dxmt } }

    func shutdownManagedSteam() async {
        steamLaunchRelayTask?.cancel()
        steamPlayRequestTask?.cancel()
        await steamLaunchRelayTask?.value
        await steamPlayRequestTask?.value
        for monitor in gameLaunchMonitors.values { monitor.cancel() }
        gameLaunchMonitors.removeAll()
        onboardingTask?.cancel()
        gptkSetupTask?.cancel()
        steamMetadataTask?.cancel()
        // Join first so an installation cannot launch Steam after shutdown.
        await onboardingTask?.value
        await gptkSetupTask?.value
        steamSessionManager.didStop()
        guard let bottle = steamBottle, let runtime = gamingWineRuntime else { return }
        let environment = ["WINEPREFIX": bottle.root.path, "WINEDEBUG": "-all",
                           "DYLD_LIBRARY_PATH": runtime.root.appendingPathComponent("lib").path]
        if let steam = steamExecutable {
            _ = try? await Subprocess().run(
                runtime.root.appendingPathComponent("bin/wine"),
                arguments: [steam.path, "-shutdown"], environment: environment,
                workingDirectory: steam.deletingLastPathComponent(),
                timeout: .seconds(10), requireSuccess: false
            )
            _ = try? await Subprocess().run(
                runtime.root.appendingPathComponent("bin/wineserver"),
                arguments: ["-w"], environment: environment,
                timeout: .seconds(8), requireSuccess: false
            )
        }
        await WineRuntimeProvider(manifest: runtime.manifest, root: runtime.root).stopBottle(bottle)
    }

    func retryOnboarding() {
        guard !onboardingBusy else { return }
        onboardingTask = Task { await runOnboarding() }
    }

    private func runOnboarding() async {
        guard !onboardingBusy else { return }
        onboardingBusy = true
        onboardingError = nil
        defer { onboardingBusy = false }
        do {
            guard let report = systemReport else {
                throw IndieError.invalidData(lastError ?? L("无法读取系统信息，请重新打开应用"))
            }
            let failures = report.items.filter { $0.severity == .failure && $0.id != "rosetta" }
            guard failures.isEmpty else {
                throw IndieError.unsupported(failures.map(\.detail).joined(separator: "；"))
            }
            // Returning users stay in the main shell while checking. Do not
            // flash a first-install screen before discovering a ready setup.
            if report.rosettaInstalled, onboardingWineReady, onboardingDXMTReady,
               onboardingGraphicsReady, steamExecutable != nil,
               UserDefaults.standard.bool(forKey: "firstRunSteamLoginCompleted") {
                onboardingStage = .complete
                await automaticallyOpenSteam()
                return
            }
            onboardingStage = .environment
            if !report.rosettaInstalled {
                onboardingMessage = L("正在安装 Apple Rosetta 2…")
                try await Subprocess().run(
                    URL(fileURLWithPath: "/usr/sbin/softwareupdate"),
                    arguments: ["--install-rosetta", "--agree-to-license"], timeout: .seconds(600)
                )
                systemReport = await probe.run()
            }
            if !onboardingWineReady {
                onboardingMessage = L("正在下载并校验 Wine 与 SDL 手柄组件…")
                await prepareEnvironment()
                guard onboardingWineReady else { throw IndieError.invalidData(lastError ?? L("Wine 安装未完成")) }
            }
            if !onboardingDXMTReady {
                onboardingMessage = L("正在安装 DXMT 图形兼容组件…")
                _ = try await communityDXMT.installLatest()
                rendererOverlays = await overlayImporter.installed()
            }
            if !onboardingGraphicsReady {
                onboardingMessage = L("正在自动下载 GPTK 4 图形组件…")
                await setupLatestGPTK()
                guard onboardingGraphicsReady else { throw IndieError.invalidData(lastError ?? L("GPTK 安装未完成")) }
            }
            try Task.checkCancellation()
            if steamExecutable != nil,
               UserDefaults.standard.bool(forKey: "firstRunSteamLoginCompleted") {
                onboardingStage = .complete
                await automaticallyOpenSteam()
                return
            }
            onboardingStage = .steam
            onboardingMessage = L("环境已就绪，正在准备 Steam…")
            try await prepareOnboardingSteam()
        } catch {
            if onboardingStage == .checking { onboardingStage = .environment }
            onboardingError = error.localizedDescription
            lastError = nil
        }
    }

    private func automaticallyOpenSteam() async {
        guard !didAutomaticallyOpenSteam, !Task.isCancelled else { return }
        didAutomaticallyOpenSteam = true
        // The first-install login flow already opens Steam itself. Returning
        // users use the normal client path, which reuses a live session safely.
        guard !isOpeningSteamClient else { return }
        await openSteamClient()
    }

    private func prepareOnboardingSteam() async throws {
        guard let runtime = gamingWineRuntime else { throw IndieError.notFound(L("Wine 尚未安装")) }
        let provider = WineRuntimeProvider(manifest: runtime.manifest, root: runtime.root)
        let bottle: BottleRecord
        if let existing = steamBottle { bottle = existing }
        else {
            bottle = try await BottleManager(paths: paths, store: store).create(name: "Steam", runtime: provider)
            bottles = try await store.bottles()
        }
        if steamExecutable == nil {
            onboardingMessage = L("正在从 Valve 官方下载并安装 Steam…")
            let installer = SteamInstaller(paths: paths)
            let staged = try await installer.stageForLaunch(try await installer.download(), in: bottle)
            try await provider.prepareBottleForInstaller(bottle)
            let plan = try LaunchPlanBuilder.build(
                executable: staged.fileURL, windowsExecutablePath: staged.windowsPath,
                bottle: bottle,
                profile: .init(runtimeID: runtime.manifest.id, preferredRenderer: .wineD3D,
                               arguments: ["/S"], environment: ["WINEDEBUG": "-all", "WINEDLLOVERRIDES": "mscoree,mshtml="]),
                analysis: try PEAnalyzer.analyze(at: staged.fileURL), recipe: nil,
                installed: .init(available: [.wineD3D])
            )
            _ = try await provider.launchDetached(plan, logURL: paths.logs.appendingPathComponent("onboarding-steam-install.log"))
            let deadline = Date().addingTimeInterval(600)
            while steamExecutable == nil {
                try Task.checkCancellation()
                guard Date() < deadline else { throw IndieError.timedOut(L("Steam 安装或更新，请检查网络后重试")) }
                try await Task.sleep(for: .seconds(2))
            }
        }
        let helper = SteamCompatibilityManager.steamRoot(in: bottle).appendingPathComponent("bin/cef/cef.win64/steamwebhelper.exe")
        if !FileManager.default.fileExists(atPath: helper.path), let steam = steamExecutable {
            onboardingMessage = L("Steam 基础安装已完成，正在下载客户端更新…")
            let updatePlan = try LaunchPlanBuilder.build(
                executable: steam, windowsExecutablePath: try WinePath.windowsPath(for: steam, in: bottle), bottle: bottle,
                profile: .init(runtimeID: runtime.manifest.id, preferredRenderer: .wineD3D,
                               arguments: ["-no-cef-sandbox"], environment: ["WINEDEBUG": "-all", "WINEDLLOVERRIDES": "mscoree,mshtml="]),
                analysis: try PEAnalyzer.analyze(at: steam), recipe: nil, installed: .init(available: [.wineD3D])
            )
            _ = try await provider.launchDetached(updatePlan, logURL: paths.logs.appendingPathComponent("onboarding-steam-update.log"))
            let deadline = Date().addingTimeInterval(900)
            while !FileManager.default.fileExists(atPath: helper.path) {
                try Task.checkCancellation()
                guard Date() < deadline else { throw IndieError.timedOut(L("Steam 客户端更新")) }
                try await Task.sleep(for: .seconds(2))
            }
            // Allow the updater to finish replacing its other client files.
            try await Task.sleep(for: .seconds(10))
        }
        guard let steam = steamExecutable,
              let wrapper = SteamCompatibilityManager.bundledWrapperURL() else {
            throw IndieError.notFound(L("Steam 登录组件不完整，请重试安装"))
        }
        try await provider.prepareBottleForInstaller(bottle)
        try await provider.configureControllerSupport(in: bottle)
        _ = try SteamCompatibilityManager.prepare(bottle: bottle, wrapper: wrapper)
        let environment = ["WINEDEBUG": "-all", "LANG": "zh_CN.UTF-8", "LC_ALL": "zh_CN.UTF-8",
                           "WINEDLLOVERRIDES": "mscoree,mshtml=;winedbg.exe=d;dxgi,d3d10,d3d10core,d3d11,d3d12=b"]
        let plan = try LaunchPlanBuilder.build(
            executable: steam, windowsExecutablePath: try WinePath.windowsPath(for: steam, in: bottle), bottle: bottle,
            profile: .init(runtimeID: runtime.manifest.id, preferredRenderer: .wineD3D,
                           arguments: SteamCompatibilityManager.launchArguments(appID: nil), environment: environment),
            analysis: .init(identity: .init(executableName: "steam.exe"), architecture: .x86_64,
                            directX: .none, antiCheat: .none, importedLibraries: []),
            recipe: nil, installed: .init(available: [.wineD3D])
        )
        let launchedAt = Date()
        _ = try await provider.launchDetached(plan, logURL: paths.logs.appendingPathComponent("onboarding-steam-login.log"))
        onboardingMessage = L("请在 Steam 官方窗口中扫码，或输入账号密码登录。登录成功后会自动进入游戏库。")
        let deadline = Date().addingTimeInterval(30 * 60)
        while !SteamCompatibilityManager.isLoggedOn(in: bottle, since: launchedAt) {
            try Task.checkCancellation()
            guard Date() < deadline else { throw IndieError.timedOut(L("Steam 登录，可点击重试重新打开登录窗口")) }
            try await Task.sleep(for: .seconds(2))
        }
        steamSessionManager.didLaunch(.init(bottleID: bottle.id, runtimeID: runtime.manifest.id,
                                           environment: plan.environment, virtualDesktop: nil), reused: false)
        try await scanDefaultSteamLibrary()
        UserDefaults.standard.set(true, forKey: "firstRunSteamLoginCompleted")
        onboardingStage = .complete
        requestedDestination = "library"
    }

    func refresh() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try paths.createDirectories()
            try await store.open()
            async let report = probe.run()
            async let savedGames = store.games()
            async let savedBottles = store.bottles()
            async let imported = importer.installedComponents()
            async let wine = wineImporter.installed()
            async let overlays = overlayImporter.installed()
            async let savedConfigurations = store.gameConfigurations()
            systemReport = await report
            games = try await savedGames
            bottles = try await savedBottles
            d3dMetal = try await imported
            wineRuntimes = await wine
            rendererOverlays = await overlays
            gameConfigurations = Dictionary(uniqueKeysWithValues: try await savedConfigurations.map { ($0.id, $0) })
            var loadedRecipes = try RecipeRepository.builtIn().recipes
            loadedRecipes.append(contentsOf: try RecipeRepository.load(from: paths.recipes).recipes)
            recipeRepository = RecipeRepository(recipes: loadedRecipes)
            try await scanDefaultSteamLibrary()
            if self.steamSessionManager.state == .running,
               (self.steamBottle.map { SteamCompatibilityManager.isLoggedOn(in: $0) } != true) {
                self.steamSessionManager.didStop()
            }
            status = L("准备就绪")
        } catch { present(error) }
    }

    func handleDeepLink(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["portlane", "macgaminguncle", "indie"].contains(scheme) else {
            present(IndieError.invalidArgument(L("无法识别 Portlane 链接：\(url.absoluteString)")))
            return
        }
        if let destination = url.host?.lowercased(),
           ["home", "store", "library", "controllers", "environment"].contains(destination) {
            requestedDestination = destination
            return
        }
        guard
              url.host?.lowercased() == "launch",
              let appIDText = url.pathComponents.dropFirst().first,
              let appID = UInt64(appIDText) else {
            present(IndieError.invalidArgument(L("无法识别 Portlane 链接：\(url.absoluteString)")))
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            while self.isWorking { try? await Task.sleep(for: .milliseconds(100)) }
            guard let game = self.steamGames.first(where: { $0.appID == appID }) else {
                self.present(IndieError.notFound(L("Steam 游戏库中没有 AppID \(appID)")))
                return
            }
            await self.launchSteamGame(game)
        }
    }

    func prepareEnvironment() async {
        await perform(L("正在安装 Portlane Wine 11 开源运行环境…")) {
            guard self.systemReport?.isSupported == true else {
                throw IndieError.unsupported(L("这台 Mac 尚未通过环境检查，请打开高级设置查看原因"))
            }
            self.status = L("正在下载并校验 Portlane Wine 11…")
            let installed = try await self.communityGamingWine.installLatest()
            self.wineRuntimes = await self.wineImporter.installed()
            self.status = L("游戏运行环境 \(installed.manifest.version) 已准备好")
        }
    }

    func importExecutable(_ url: URL) async {
        await perform(L("正在分析 \(url.lastPathComponent)…")) {
            let analysis = try PEAnalyzer.analyze(at: url)
            let game = GameRecord(displayName: url.deletingPathExtension().lastPathComponent, source: .local, executableURL: url, analysis: analysis)
            try await self.store.saveGame(game)
            self.games = try await self.store.games()
            self.status = L("已导入 \(url.lastPathComponent)：\(analysis.architecture.rawValue) / \(analysis.directX.rawValue)")
        }
    }

    func scanSteam(_ steamApps: URL) async {
        await perform(L("正在扫描 Steam 游戏库…")) {
            let records = try SteamScanner.scan(steamApps: steamApps)
            self.steamGames = records.filter(\.isReadyToPlay)
            self.steamDownloads = records.filter { !$0.isReadyToPlay && $0.appID != 228980 }
            self.status = L("发现 \(self.steamGames.count) 个 Steam 游戏")
        }
    }

    func installSteam() async {
        await perform(L("正在从 Valve 官方 CDN 下载 Steam…")) {
            guard let runtime = self.gamingWineRuntime else {
                throw IndieError.notFound(L("请先准备 Portlane Wine 11 开源运行环境"))
            }
            let steamInstaller = SteamInstaller(paths: self.paths)
            let installer = try await steamInstaller.download()
            let provider = WineRuntimeProvider(manifest: runtime.manifest, root: runtime.root)
            let bottle = if let existing = self.bottles.first(where: { $0.name == "Steam" }) {
                existing
            } else {
                try await BottleManager(paths: self.paths, store: self.store).create(name: "Steam", runtime: provider)
            }
            await provider.stopBottle(bottle)
            self.steamSessionManager.didStop()
            try await provider.prepareBottleForInstaller(bottle)
            try await provider.configureControllerSupport(in: bottle)
            let stagedInstaller = try await steamInstaller.stageForLaunch(installer, in: bottle)
            let analysis = try PEAnalyzer.analyze(at: stagedInstaller.fileURL)
            let profile = LaunchProfile(
                runtimeID: runtime.manifest.id,
                preferredRenderer: .wineD3D,
                environment: ["LANG": "zh_CN.UTF-8", "LC_ALL": "zh_CN.UTF-8"]
            )
            let plan = try LaunchPlanBuilder.build(
                executable: stagedInstaller.fileURL,
                windowsExecutablePath: stagedInstaller.windowsPath,
                bottle: bottle, profile: profile, analysis: analysis,
                recipe: nil, installed: InstalledRenderers(available: [.wineD3D])
            )
            let log = self.paths.logs.appendingPathComponent("\(plan.id.uuidString)-steam-install.log")
            self.status = L("请在 Wine 窗口中完成 Steam 安装…")
            let session = await provider.launch(plan, logURL: log)
            try await self.store.saveSession(session)
            self.bottles = try await self.store.bottles()
            let steamApps = bottle.root.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps", isDirectory: true)
            if FileManager.default.fileExists(atPath: steamApps.path) {
                let records = try SteamScanner.scan(steamApps: steamApps)
                self.steamGames = records.filter(\.isReadyToPlay)
                self.steamDownloads = records.filter { !$0.isReadyToPlay && $0.appID != 228980 }
            }
            self.status = L("Steam 安装流程已结束")
        }
    }

    func launchSteam(appID: UInt64? = nil) async {
        if let appID {
            if let game = steamGames.first(where: { $0.appID == appID }) {
                await launchSteamGame(game)
            } else { await openSteamClient(.game(appID)) }
        } else {
            await openSteamClient()
        }
    }

    func openSteamGameProperties(appID: UInt64) async {
        guard appID > 0, appID <= UInt32.max else { return }
        await sendSteamURI("steam://gameproperties/\(appID)", status: L("正在打开 Steam 游戏属性…"))
    }

    func launchSteamGame(_ game: SteamGame, fromSteamPlay: Bool = false) async {
        guard !isWorking, gameLaunchStates[game.appID]?.blocksLaunch != true else { return }
        gameLaunchReports[game.appID] = GameLaunchReport(appID: game.appID, name: game.name)
        updateGameLaunch(game.appID, .preparing, L("检查游戏文件与运行组件"))
        await perform(L("正在为 \(game.name) 选择最佳图形后端…")) {
            guard fromSteamPlay || SteamDownloadBridge.permitsPlay(
                manifestReady: (try? SteamScanner.refreshed(game).isReadyToPlay) == true,
                download: self.steamBridgeDownloads[game.appID]) else {
                try await self.scanDefaultSteamLibrary()
                throw IndieError.invalidData(L("游戏尚未安装完成，请等待 Steam 完成下载和校验"))
            }
            guard let bottle = self.steamBottle else {
                throw IndieError.notFound(L("尚未完成 Steam 安装"))
            }
            guard let gamingRuntime = self.gamingWineRuntime else {
                throw IndieError.notFound(L("需要 Portlane Wine 11 游戏引擎，请重新运行环境准备"))
            }
            let gamingProvider = WineRuntimeProvider(manifest: gamingRuntime.manifest, root: gamingRuntime.root)
            let executable = try SteamExecutableResolver.shippingExecutable(for: game)
            let runningPath = try WinePath.windowsPath(for: executable, in: bottle)
            if try await GameProcessProbe.isRunning(windowsPath: runningPath) {
                self.monitorGameLaunch(appID: game.appID, windowsPath: runningPath, alreadyRunning: true)
                return
            }
            self.updateGameLaunch(game.appID, .preparing, L("分析游戏兼容性与图形后端"))
            self.status = L("正在快速检查游戏兼容性…")
            let analysis = try await Task.detached(priority: .userInitiated) {
                try PEAnalyzer.analyze(at: executable, steamAppID: game.appID)
            }.value
            let configuration = self.configuration(for: game)
            let recipe = self.recipeRepository.match(analysis)
            if (configuration.preferredRenderer == .dxmt || recipe?.profiles.first?.renderer == .dxmt),
               !self.rendererOverlays.contains(where: { $0.kind == .dxmt }) {
                self.updateGameLaunch(game.appID, .preparing, L("下载并安装所需的 DXMT 组件"))
                self.status = L("正在安装 \(game.name) 所需的 DXMT 0.80…")
                _ = try await self.communityDXMT.installLatest()
                self.rendererOverlays = await self.overlayImporter.installed()
            }
            var availableRenderers: Set<RendererKind> = [.wineD3D]
            var overlayPaths: [RendererKind: URL] = [:]
            if let component = self.preferredD3DMetal,
               let renderer = component.rendererRoot,
               Self.majorVersion(component.version) >= 4 {
                availableRenderers.insert(.d3dMetal)
                overlayPaths[.d3dMetal] = renderer.appendingPathComponent("wine", isDirectory: true)
            }
            for overlay in self.rendererOverlays where overlay.kind == .dxmt {
                availableRenderers.insert(.dxmt)
                overlayPaths[.dxmt] = overlay.root
            }
            let installedRenderers = InstalledRenderers(available: availableRenderers, overlayPaths: overlayPaths)
            let resolution = try RendererResolver.resolve(
                analysis: analysis,
                preferred: configuration.preferredRenderer,
                recipe: recipe,
                installed: installedRenderers
            )
            self.updateGameLaunch(game.appID, .preparing, L("应用专属 Mac 配置") + " · " + resolution.renderer.rawValue.uppercased())
            let recipeProfile = recipe?.profiles.first { $0.renderer == resolution.renderer }
            let recipeArguments = recipeProfile?.arguments ?? []
            let displayPolicy = GameDisplaySnapshot.policy(
                retinaEnabled: game.appID == 219990 ? false : (recipeProfile?.highResolution ?? true)
            )
            // Dota's cooperative fullscreen keeps the desktop mode unchanged.
            // Keep this game-specific; other games have different DPI semantics.
            if game.appID == 570, resolution.renderer == .d3dMetal,
               configuration.virtualDesktop == nil {
                _ = try Dota2Compatibility.prepare(
                    steamRoot: SteamCompatibilityManager.steamRoot(in: bottle)
                )
            }

            let wantsMetalHUD = configuration.metalHUD.resolve(
                default: UserDefaults.standard.bool(forKey: "metalHUD")
            )
            // Both D3DMetal and DXMT submit work directly to Metal. Keep the
            // Apple HUD available for either backend; restricting it to
            // D3DMetal made the setting appear broken for DX11 titles whose
            // compatibility recipe deliberately selects DXMT.
            let metalHUDEnabled = wantsMetalHUD && [.d3dMetal, .dxmt].contains(resolution.renderer)
            let metalFXEnabled = configuration.metalFX.resolve(
                default: UserDefaults.standard.bool(forKey: "metalFX")
            ) &&
                resolution.renderer == .d3dMetal && recipeProfile?.metalFX != false
            let wantsMetal4 = UserDefaults.standard.object(forKey: "metal4") as? Bool ?? true
            let metal4Enabled = configuration.metal4.resolve(default: wantsMetal4) &&
                recipeProfile?.metal4 != false && Self.supportsMetal4
            var environment = [
                "LANG": "zh_CN.UTF-8",
                "LC_ALL": "zh_CN.UTF-8",
                "WINEDEBUG": "-all",
            ]
            var needsWarmupProtection = false
            if resolution.renderer == .d3dMetal {
                guard let component = self.preferredD3DMetal,
                      let renderer = component.rendererRoot else {
                    throw IndieError.notFound(L("请先使用“一键安装 GPTK 4”导入 D3DMetal"))
                }
                environment = try D3DMetalLaunchEnvironment.make(
                    rendererRoot: renderer,
                    runtimeRoot: gamingRuntime.root,
                    metalHUD: metalHUDEnabled,
                    metalFX: metalFXEnabled,
                    metal4: metal4Enabled
                )
                let shaderPreparation = try D3DMetalShaderCacheManager.prepare(
                    executableName: executable.lastPathComponent,
                    profile: D3DMetalShaderProfile(
                        rendererVersion: component.version,
                        rendererSHA256: component.sourceSHA256,
                        metalFX: metalFXEnabled,
                        dxr: false,
                        metal4: metal4Enabled,
                        launchArguments: recipeArguments
                    ),
                    backupRoot: self.paths.shaderCacheBackups
                )
                needsWarmupProtection = shaderPreparation.needsWarmupProtection
            } else if resolution.renderer == .wineD3D {
                environment["CX_ACTIVE_GRAPHICS_BACKEND"] = "wined3d"
                environment["WINEDLLOVERRIDES"] = "dxgi,d3d10,d3d10core,d3d11,d3d12=b"
            }

            var gameEnvironment = environment
            gameEnvironment.merge(SpatialAudioDiagnostics.environment(
                enabled: configuration.spatialAudioDiagnostics == true
            )) { _, configured in configured }
            gameEnvironment.merge(
                ControllerLaunchEnvironment.make(
                    mode: configuration.controllerMode,
                    rumble: configuration.controllerRumble
                )
            ) { _, configured in configured }
            // Steam supplies the correct AppID to each child. Keeping an AppID
            // on the long-lived Steam process would leak the first game's ID
            // into later launches when the client is reused.
            // Steam owns executable selection for `-applaunch`; only pass
            // compatibility switches here. Positional launcher shims are for
            // direct EXE execution and would corrupt Steam launch options.
            var gameArguments = configuration.arguments
            if game.appID == 570 {
                // Respect explicit per-game limits; do not inherit the launcher's
                // previous diagnostic 60 FPS cap or Steam's default legacy VSync.
                for (key, value) in [("+fps_max", "120"), ("+fps_max_ui", "120"), ("+r_legacy_vsync", "0")] {
                    if !gameArguments.contains(key) { gameArguments += [key, value] }
                }
            }
            if needsWarmupProtection,
               executable.lastPathComponent.lowercased().contains("-win64-shipping") {
                // D3DMetal may need more than UE's 120-second RenderThread
                // watchdog allowance while rebuilding a large pipeline cache.
                if !gameArguments.contains("-nothreadtimeout") && !recipeArguments.contains("-nothreadtimeout") {
                    gameArguments.append("-nothreadtimeout")
                }
            }
            let gameProfile = LaunchProfile(
                runtimeID: gamingProvider.manifest.id,
                preferredRenderer: resolution.renderer,
                syncBackend: configuration.syncBackend,
                arguments: gameArguments,
                environment: gameEnvironment,
                metalHUD: metalHUDEnabled,
                virtualDesktop: configuration.virtualDesktop
            )
            let gamePlan = try LaunchPlanBuilder.build(
                executable: executable,
                windowsExecutablePath: try WinePath.windowsPath(for: executable, in: bottle),
                bottle: bottle, profile: gameProfile, analysis: analysis,
                recipe: recipe,
                installed: installedRenderers
            )
            if let option = recipeProfile?.steamLaunchOption {
                _ = try SteamCompatibilityManager.setDefaultLaunchOption(
                    appID: game.appID, option: option, in: bottle
                )
            }
            guard let steam = self.steamExecutable else { throw IndieError.notFound(L("尚未完成 Steam 安装")) }
            let steamAnalysis = GameAnalysis(
                identity: GameIdentity(steamAppID: game.appID, executableName: "steam.exe"),
                architecture: .x86_64, directX: .none, antiCheat: .none, importedLibraries: []
            )
            let steamProfile = LaunchProfile(
                runtimeID: gamingRuntime.manifest.id,
                preferredRenderer: .wineD3D,
                syncBackend: gamePlan.environment["WINEMSYNC"] == "1" ? .msync : .wineserver,
                arguments: SteamCompatibilityManager.launchArguments(
                    appID: game.appID,
                    gameArguments: gamePlan.arguments,
                    launchOption: recipeProfile?.steamLaunchOption,
                    silent: true
                ),
                environment: SteamCompatibilityManager.relayEnvironment(for: gamePlan.environment, appID: game.appID),
                metalHUD: false,
                virtualDesktop: configuration.virtualDesktop
            )
            let baseSteamPlan = try LaunchPlanBuilder.build(
                executable: steam,
                windowsExecutablePath: try WinePath.windowsPath(for: steam, in: bottle),
                bottle: bottle, profile: steamProfile, analysis: steamAnalysis,
                recipe: nil, installed: InstalledRenderers(available: [.wineD3D])
            )
            let steamPlan = baseSteamPlan.withEnvironment(
                try GameCompatibilityEnvironment.applying(configuration, to: baseSteamPlan.environment))
            let descriptor = SteamSessionDescriptor(
                bottleID: bottle.id,
                runtimeID: gamingRuntime.manifest.id,
                environment: steamPlan.environment,
                virtualDesktop: configuration.virtualDesktop,
                displayPolicy: displayPolicy
            )
            let reusingSteam = self.steamSessionManager.canReuse(descriptor) &&
                SteamCompatibilityManager.isLoggedOn(in: bottle)
            self.updateGameLaunch(game.appID, .preparing, reusingSteam ? L("连接已登录的 Steam 会话") : L("检查共享会话并准备 Steam 运行环境"))
            if !reusingSteam {
                let downloads: [SteamBridgeDownload]
                if SteamCompatibilityManager.isLoggedOn(in: bottle), let bridge = self.downloadBridge() {
                    // Fail closed if a live client's download state cannot be
                    // checked before restarting its shared environment.
                    downloads = try await bridge.downloads()
                } else { downloads = [] }
                guard !downloads.contains(where: { !$0.completed && !$0.paused }) else {
                    throw IndieError.invalidArgument(L("此游戏需要切换 Steam 运行环境，请先暂停 Steam 下载再启动"))
                }
                // A DPI/topology change requires stopping the shared prefix.
                // Never silently interrupt another game, including one opened in Steam.
                for installedGame in self.steamGames {
                    guard let otherExecutable = try? SteamExecutableResolver.shippingExecutable(for: installedGame) else { continue }
                    let otherPath = try WinePath.windowsPath(for: otherExecutable, in: bottle)
                    if try await GameProcessProbe.isRunning(windowsPath: otherPath) {
                        throw IndieError.invalidArgument(L("请先退出正在运行的游戏，再切换显示或运行环境设置"))
                    }
                }
                self.steamSessionManager.didStop()
                self.updateGameLaunch(game.appID, .preparing, L("配置 Wine、显示与手柄支持"))
                self.status = L("正在准备全局 Steam 会话…")
                try await gamingProvider.prepareBottleForInstaller(bottle)
                // Apply only after all old Wine processes have stopped. The reg
                // helper itself starts Wine, so stop it before creating Steam.
                _ = try await Subprocess().run(
                    gamingProvider.wineBinary, arguments: displayPolicy.registryArguments,
                    environment: ["WINEPREFIX": bottle.root.path,
                                  "DYLD_LIBRARY_PATH": gamingRuntime.root.appendingPathComponent("lib").path,
                                  "WINEDEBUG": "-all"], timeout: .seconds(30)
                )
                await gamingProvider.stopBottle(bottle)
                try await gamingProvider.configureControllerSupport(in: bottle)
                guard let wrapper = SteamCompatibilityManager.bundledWrapperURL() else {
                    throw IndieError.notFound(L("Portlane 缺少 Steam 界面兼容组件，请重新安装应用"))
                }
                _ = try SteamCompatibilityManager.prepare(bottle: bottle, wrapper: wrapper)
                if resolution.renderer == .d3dMetal,
                   let component = self.preferredD3DMetal,
                   let renderer = component.rendererRoot {
                    try D3DMetalRendererPreparer.installBridge(
                        rendererRoot: renderer, version: component.version, bottle: bottle
                    )
                    if metalFXEnabled {
                        try D3DMetalRendererPreparer.enableMetalFX(
                            rendererRoot: renderer, version: component.version, bottle: bottle
                        )
                    }
                } else if resolution.renderer == .wineD3D {
                    try await gamingProvider.configureWineD3DGraphics(in: bottle)
                }
            }
            if game.appID == 219990 {
                self.status = L("正在应用 Grim Dawn 1.3 HUD 兼容配置…")
                // Wine uses the primary monitor; NSScreen.main may instead be
                // the screen containing the launcher's key window.
                // screenMode=0 is fullscreen in Grim Dawn. The render size
                // must match the full monitor, not its desktop work area.
                let screen = NSScreen.screens.first?.frame.size
                let safeResolution = configuration.virtualDesktop?.label.replacingOccurrences(of: " × ", with: " ")
                    ?? GrimDawnCompatibility.logicalDisplayResolution(
                        width: screen.map { Double($0.width) },
                        height: screen.map { Double($0.height) }
                    )
                _ = try GrimDawnCompatibility.prepare(bottleRoot: bottle.root, safeResolution: safeResolution)
            }
            let launchPlan = reusingSteam ? steamPlan.withoutVirtualDesktop() : steamPlan
            let log = self.paths.logs.appendingPathComponent("\(launchPlan.id.uuidString)-steam-\(resolution.renderer.rawValue).log")
            let architecture = analysis.architecture == .x86_64 ? "x64" : analysis.architecture.rawValue
            self.status = reusingSteam
                ? L("正在通过已登录的 Steam 启动 \(game.name)…")
                : needsWarmupProtection
                ? L("\(game.name) 正在首次构建图形缓存，可能需要几分钟…")
                : L("正在由 Steam 启动 \(game.name) · \(architecture) + \(resolution.renderer.rawValue.uppercased())\(metal4Enabled ? " + Metal 4" : "")")
            self.gameLaunchReports[game.appID]?.logURL = log
            self.updateGameLaunch(game.appID, .preparing, L("向 Steam 发送启动命令"))
            _ = try await gamingProvider.launchDetached(launchPlan, logURL: log)
            self.steamSessionManager.didLaunch(descriptor, reused: reusingSteam)
            self.monitorGameLaunch(appID: game.appID, windowsPath: try WinePath.windowsPath(for: executable, in: bottle))
        }
        if gameLaunchStates[game.appID] == .preparing {
            let failedStep = gameLaunchReports[game.appID]?.steps.last?.detail ?? ""
            updateGameLaunch(game.appID, .failed, L("启动失败") + " · " + failedStep,
                             error: lastError ?? L("启动操作已取消"))
        }
    }

    private func updateGameLaunch(_ appID: UInt64, _ state: GameLaunchState, _ detail: String, error: String? = nil) {
        gameLaunchStates[appID] = state
        gameLaunchReports[appID]?.update(state, detail: detail, error: error)
    }

    private func monitorGameLaunch(appID: UInt64, windowsPath: String, alreadyRunning: Bool = false) {
        gameLaunchMonitors[appID]?.cancel()
        updateGameLaunch(appID, alreadyRunning ? .running : .waiting, alreadyRunning ? L("检测到游戏进程") : L("启动命令已发送，等待游戏进程（最多 120 秒）"))
        gameLaunchMonitors[appID] = Task { [weak self] in
            let deadline = Date().addingTimeInterval(120)
            var didRun = alreadyRunning
            var firstSeenAt: Date? = alreadyRunning ? Date().addingTimeInterval(-15) : nil
            var consecutiveMissing = 0
            while !Task.isCancelled {
                do {
                    let running = try await GameProcessProbe.isRunning(windowsPath: windowsPath)
                    guard let self, !Task.isCancelled else { return }
                    if running {
                        if firstSeenAt == nil { firstSeenAt = Date() }
                        didRun = true
                        consecutiveMissing = 0
                        self.updateGameLaunch(appID, .running, L("检测到游戏进程"))
                    } else if didRun {
                        consecutiveMissing += 1
                        if consecutiveMissing >= 2 {
                            if let firstSeenAt, Date().timeIntervalSince(firstSeenAt) < 15 {
                                self.updateGameLaunch(appID, .unconfirmed, L("游戏进程很快退出"), error: L("进程启动后很快退出，可能是正常关闭或启动异常。请查看日志确认。"))
                            } else {
                                self.updateGameLaunch(appID, .idle, L("游戏进程已退出"))
                            }
                            self.gameLaunchMonitors[appID] = nil
                            return
                        }
                    } else if Date() >= deadline {
                        self.updateGameLaunch(appID, .unconfirmed, L("未能确认游戏启动"), error: L("120 秒内未检测到游戏进程。请检查 Steam 登录、下载校验或启动弹窗，并查看日志；游戏也可能仍在准备中。"))
                        self.gameLaunchMonitors[appID] = nil
                        return
                    }
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    if Task.isCancelled { return }
                    self?.updateGameLaunch(appID, .unconfirmed, L("无法检查游戏进程"), error: error.localizedDescription)
                    self?.gameLaunchMonitors[appID] = nil
                    return
                }
            }
        }
    }

    private static var supportsMetal4: Bool {
        if #available(macOS 26.0, *) {
            return MTLCreateSystemDefaultDevice()?.supportsFamily(.metal4) == true
        }
        return false
    }

    func rescanSteam() {
        Task {
            do {
                steamMetadataRetry.reset()
                try await scanDefaultSteamLibrary()
                status = steamGames.isEmpty ? L("尚未发现已安装的 Steam 游戏") : L("发现 \(steamGames.count) 个 Steam 游戏")
            } catch { present(error) }
        }
    }

    func installSteamGame(appID: UInt64, library: SteamLibraryLocation? = nil) async {
        guard appID > 0, appID <= UInt32.max, !submittingSteamInstall, !isWorking,
              steamInstallationRequests[appID]?.blocksSubmission != true else { return }
        let owned = steamAccountGames.contains { $0.appID == appID } ||
            steamGames.contains { $0.appID == appID } || steamDownloads.contains { $0.appID == appID }
        guard owned else {
            await openSteamClient(.store(appID), notice: L("请先在 Steam 中获取游戏，然后返回安装"))
            return
        }
        guard let library else {
            refreshSteamLibraryLocations()
            steamStorageError = nil
            pendingSteamInstall = .init(id:appID,name:steamAccountGames.first(where: { $0.appID == appID })?.name ?? String(appID))
            return
        }
        guard library.isWritable, let root = library.root, let bottle = steamBottle,
              WineDrivePaths.hostURL(for:library.windowsPath,bottleRoot:bottle.root)?.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path else {
            steamClientNotice = L("目标磁盘不可用或只读，请重新选择游戏库")
            return
        }
        UserDefaults.standard.set(library.id,forKey:"preferredSteamLibraryID")
        submittingSteamInstall = true
        steamInstallationRequests[appID] = .preparing
        defer { submittingSteamInstall = false }
        await sendSteamURI("", status: L("正在连接 Steam 后台…"), showWindow: false)
        guard let bridge = downloadBridge() else {
            steamInstallationRequests[appID] = .failed
            return
        }
        do {
            var connected = false
            for _ in 0..<12 {
                do { _ = try await bridge.downloads(); connected = true; break }
                catch { try await Task.sleep(for: .seconds(1)) }
            }
            guard connected else { throw IndieError.notFound(L("Steam 后台连接尚未就绪")) }
            guard try await bridge.isAuthenticated() else {
                steamAuthenticationRequired = true
                steamInstallationRequests[appID] = .confirmation
                steamClientNotice = L("Steam 尚未联机，请打开 Steam 客户端恢复连接后重试")
                return
            }
            guard let steam = steamExecutable else { throw IndieError.notFound("No Steam executable") }
            let snapshot = try await SteamClientProcessSnapshot.read(steamExecutable: steam)
            try await bridge.beginBackgroundPresentation()
            var presentationRetained = false
            defer {
                if !presentationRetained { Task { await bridge.endBackgroundPresentation() } }
            }
            SteamClientActivation.hide(snapshot)
            try? await bridge.hideClientWindow()
            let installResult = try await bridge.install(appID: appID,libraryPath:library.windowsPath)
            switch installResult {
            case .loginRequired:
                steamAuthenticationRequired = true
                steamInstallationRequests[appID] = .confirmation
                steamClientNotice = L("Steam 尚未联机，请打开 Steam 客户端恢复连接后重试")
            case .submitted:
                steamAuthenticationRequired = false
                steamInstallationRequests[appID] = .waiting
                steamInstallSubmittedAt[appID] = Date()
                backgroundSteamWindowTask?.cancel()
                presentationRetained = true
                backgroundSteamWindowTask = Task { [weak self] in
                    defer { Task { await bridge.endBackgroundPresentation() } }
                    var settled: Date?
                    while !Task.isCancelled {
                        guard let self else { return }
                        try? await bridge.touchBackgroundPresentation()
                        let pending = self.steamDownloads.contains(where: { $0.appID == appID }) ||
                            self.steamInstallationRequests[appID]?.blocksSubmission == true
                        if pending { settled = nil }
                        else if settled == nil { settled = Date() }
                        if let settled, Date().timeIntervalSince(settled) > 3 { return }
                        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    }
                }
                steamClientNotice = L("已提交给 Steam，正在等待下载和校验；完成前不会启用开始游戏")
            case .needsInteraction:
                steamInstallationRequests[appID] = .confirmation
                steamClientNotice = L("Steam 需要额外确认。仅在你点击“在 Steam 中查看”时打开客户端")
            case .failed(let code):
                try? await scanDefaultSteamLibrary()
                if steamGames.contains(where: { $0.appID == appID }) {
                    steamInstallationRequests[appID] = nil
                    steamClientNotice = L("游戏已完成安装和校验")
                } else if code == 12 || code == 15 {
                    steamInstallationRequests[appID] = .failed
                    steamClientNotice = code == 12 ? L("所选磁盘空间不足，请重新选择游戏库") : L("目标磁盘不可用或只读，请重新选择游戏库")
                } else if steamDownloads.contains(where: { $0.appID == appID }) {
                    steamInstallationRequests[appID] = .waiting
                    steamInstallSubmittedAt[appID] = Date()
                    steamClientNotice = L("Steam 正在后台下载，完成校验后即可开始游戏")
                } else {
                    steamInstallationRequests[appID] = .failed
                    steamClientNotice = [6,7].contains(code)
                        ? L("Steam 下载服务连接失败，后台重试后仍未恢复。请稍后重试；客户端不会自动弹出")
                        : L("Steam 安装失败，错误码 \(code)。请重试或手动在 Steam 中查看")
                }
            }
        } catch {
            steamInstallationRequests[appID] = .failed
            if let bottle = steamBottle, !SteamCompatibilityManager.isLoggedOn(in: bottle) {
                steamInstallationRequests[appID] = .confirmation
                steamClientNotice = L("请先登录 Steam，登录后返回重试安装")
            } else {
                steamClientNotice = L("Steam 后台连接失败。可重试或打开 Steam；更新兼容组件后需退出并重新打开 Steam")
            }
        }
        await syncSteamLibrary()
    }

    private func downloadBridge() -> SteamDownloadBridge? {
        guard let root = steamExecutable?.deletingLastPathComponent() else { return nil }
        if steamBridgeRoot != root {
            steamBridgeRoot = root
            steamDownloadBridge = SteamDownloadBridge(steamDirectory: root)
            steamBridgeDownloads = [:]
        }
        return steamDownloadBridge
    }

    func refreshSteamLibraryLocations() {
        guard let steam = steamExecutable?.deletingLastPathComponent(), let bottle = steamBottle else { return }
        steamLibraries = SteamLibraryLocation.load(steamRoot:steam,bottleRoot:bottle.root)
    }

    func offlineLibrary(for appID: UInt64) -> SteamLibraryLocation? {
        guard !steamGames.contains(where: { $0.appID == appID }) else { return nil }
        return steamLibraries.first { !$0.isAvailable && $0.appIDs.contains(appID) }
    }

    func chooseSteamLibraryFolder() async {
        guard !isWorking, !isManagingSteamStorage, !submittingSteamInstall else { return }
        guard var root = SteamFileDialog.choose(title: L("挂载游戏库"), directories: true, createDirectories: true) else { return }
        if root.lastPathComponent.lowercased() == "steamapps" { root.deleteLastPathComponent() }
        root = root.standardizedFileURL.resolvingSymlinksInPath()
        let volumeRoot = (try? root.resourceValues(forKeys:[.volumeURLKey]))?.volume
        guard root.path != "/", root.path != "/Volumes", root.path != volumeRoot?.path,
              !root.pathComponents.contains("steamapps"),
              FileManager.default.isWritableFile(atPath:root.path) else {
            steamStorageError = L("请选择可写的游戏库根目录，不要选择磁盘根目录或游戏内部文件夹")
            return
        }
        isManagingSteamStorage = true; steamStorageError = nil
        defer { isManagingSteamStorage = false }
        await sendSteamURI("",status:L("正在连接 Steam 后台…"),showWindow:false)
        do {
            guard let bottle = steamBottle, let bridge = downloadBridge() else { throw IndieError.notFound(L("Steam 后台连接尚未就绪")) }
            let windowsPath = try WinePath.windowsPath(for:root,in:bottle)
            try await bridge.addLibrary(windowsPath:windowsPath)
            refreshSteamLibraryLocations()
            await syncSteamLibrary()
        } catch { steamStorageError = error.localizedDescription }
    }

    func uninstallSteamGame(_ game: SteamGame) async {
        guard !isWorking, !submittingSteamInstall, gameLaunchStates[game.appID]?.blocksLaunch != true,
              !uninstallingSteamAppIDs.contains(game.appID) else { return }
        uninstallingSteamAppIDs.insert(game.appID)
        defer { uninstallingSteamAppIDs.remove(game.appID) }
        await sendSteamURI("", status: L("正在连接 Steam 后台…"), showWindow: false)
        await perform(L("正在卸载…")) {
            guard let bridge = self.downloadBridge(), let bottle = self.steamBottle else {
                throw IndieError.notFound(L("Steam 后台连接尚未就绪"))
            }
            guard FileManager.default.fileExists(atPath:game.manifestURL.path) else {
                throw IndieError.notFound(L("游戏库不可访问，请连接磁盘后再卸载"))
            }
            if let executable = try? SteamExecutableResolver.shippingExecutable(for: game) {
                let path = try WinePath.windowsPath(for: executable, in: bottle)
                guard try await !GameProcessProbe.isRunning(windowsPath: path) else {
                    throw IndieError.invalidArgument(L("请先退出游戏，再进行卸载"))
                }
            }
            try await bridge.uninstall(appID: game.appID)
            for _ in 0..<120 {
                if !FileManager.default.fileExists(atPath: game.manifestURL.path) {
                    guard FileManager.default.fileExists(atPath:game.manifestURL.deletingLastPathComponent().path) else {
                        throw IndieError.notFound(L("磁盘已断开，尚未确认卸载完成"))
                    }
                    self.steamInstallationRequests[game.appID] = nil
                    self.steamBridgeDownloads[game.appID] = nil
                    self.steamDownloadSpeeds[game.appID] = nil
                    try await self.scanDefaultSteamLibrary()
                    self.steamClientNotice = L("游戏已卸载，可随时重新安装")
                    return
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw IndieError.notFound(L("尚未确认卸载完成，请在 Steam 中查看"))
        }
    }

    private func pollSteamDownloads() {
        guard steamBridgePoll == nil, let bridge = downloadBridge() else { return }
        steamBridgePoll = Task { [weak self] in
            guard let self else { return }
            defer { self.steamBridgePoll = nil }
            do {
                let values = try await bridge.downloads()
                self.steamAuthenticationRequired = !(try await bridge.isAuthenticated())
                self.steamBridgeDownloads = Dictionary(values.map { ($0.appID, $0) }, uniquingKeysWith: { _, b in b })
            } catch {
                // Never keep an obsolete percent/paused state after disconnect or client restart.
                self.steamBridgeDownloads = [:]
            }
            try? await self.scanDefaultSteamLibrary(force: false)
            let now = Date()
            let pendingIDs = Set(self.steamDownloads.map(\.appID))
            self.downloadByteSamples = self.downloadByteSamples.filter { pendingIDs.contains($0.key) }
            self.steamDownloadSpeeds = self.steamDownloadSpeeds.filter { pendingIDs.contains($0.key) }
            for game in self.steamDownloads {
                guard let bytes = game.bytesDownloaded else { continue }
                if let previous = self.downloadByteSamples[game.appID], now.timeIntervalSince(previous.1) > 0 {
                    self.steamDownloadSpeeds[game.appID] = bytes >= previous.0
                        ? Double(bytes - previous.0) / now.timeIntervalSince(previous.1) : 0
                }
                self.downloadByteSamples[game.appID] = (bytes,now)
            }
            for id in Array(self.steamInstallationRequests.keys) {
                if self.steamGames.contains(where: { $0.appID == id }) {
                    self.steamInstallationRequests[id] = nil
                    self.steamInstallSubmittedAt[id] = nil
                    if self.steamClientNotice == L("已提交给 Steam，正在等待下载和校验；完成前不会启用开始游戏") ||
                        self.steamClientNotice == L("Steam 正在后台下载，完成校验后即可开始游戏") {
                        self.steamClientNotice = L("游戏已完成安装和校验")
                    }
                } else if let item = self.steamBridgeDownloads[id], item.errorCode > 1 {
                    self.steamInstallationRequests[id] = .failed
                } else if self.steamInstallationRequests[id] == .waiting,
                          self.steamDownloads.contains(where: { $0.appID == id }) == false,
                          self.steamBridgeDownloads[id] == nil,
                          let submitted = self.steamInstallSubmittedAt[id],
                          Date().timeIntervalSince(submitted) > 120 {
                    self.steamInstallationRequests[id] = .failed
                }
            }
        }
    }

    func openSteamClient(_ destination: SteamClientDestination = .library, notice: String? = nil) async {
        backgroundSteamWindowTask?.cancel()
        backgroundSteamWindowTask = nil
        if let bridge = downloadBridge() { await bridge.endBackgroundPresentation(showPending:true) }
        await sendSteamURI(destination.uri, status: L("正在打开 Steam 客户端…"),
            completion: notice)
    }

    func loadNativeSteamStore(force: Bool = false) async {
        guard !isSteamStoreLoading else { return }
        if !force, steamStoreCatalog != nil,
           let loadedAt = steamStoreLoadedAt, Date().timeIntervalSince(loadedAt) < 15 * 60 { return }
        isSteamStoreLoading = true
        steamStoreError = nil
        defer { isSteamStoreLoading = false }
        if steamStoreCatalog == nil {
            steamStoreCatalog = SteamNativeStoreCache.load(from: paths.steamNativeStoreCache)
        }
        do {
            let catalog = try await SteamNativeStoreService.featured()
            steamStoreCatalog = catalog
            try? SteamNativeStoreCache.save(catalog, to: paths.steamNativeStoreCache)
            steamStoreLoadedAt = Date()
        } catch {
            if steamStoreCatalog == nil {
                steamStoreError = L("Steam 商店暂时无法连接：\(error.localizedDescription)")
            }
        }
    }

    func resetSteamSearch(_ query: String) {
        steamSearchTask?.cancel()
        steamSearchTask = nil
        steamSearchState.reset(query)
    }

    func searchNativeSteamStore(_ query: String) async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if term == steamSearchQuery, isSteamSearchLoading || steamSearchCompleted { return }
        resetSteamSearch(term)
        guard term.count >= 2 else { return }
        let requestID = steamSearchState.begin(term)
        let task = Task { try await SteamNativeStoreService.search(term) }
        steamSearchTask = task
        do {
            let results = try await task.value
            guard !task.isCancelled else { return }
            steamSearchState.complete(results, requestID: requestID)
        } catch {
            guard !task.isCancelled else { return }
            steamSearchState.fail(L("搜索失败：\(error.localizedDescription)"), requestID: requestID)
        }
    }

    func openSteamStore(appID: UInt64) {
        guard let url = URL(string: "https://store.steampowered.com/app/\(appID)/?l=\(AppLanguage.steamLanguage)") else { return }
        NSWorkspace.shared.open(url)
    }

    func handleSteamWebURL(_ url: URL) {
        guard url.scheme?.lowercased() == "steam" else { return }
        Task { await sendSteamURI(url.absoluteString, status: L("正在交给 Steam 处理…")) }
    }

    func importGPTK(_ url: URL) async {
        await perform(L("正在验证并导入 Apple D3DMetal…")) {
            let component = try await self.importer.importFromAppleImage(url)
            self.d3dMetal = try await self.importer.installedComponents()
            self.status = L("D3DMetal \(component.version) 已导入")
        }
    }

    func startGPTKSetup() {
        guard gptkSetupTask == nil else { return }
        gptkSetupTask = Task { [weak self] in
            guard let self else { return }
            await self.setupLatestGPTK()
            self.gptkSetupTask = nil
        }
    }

    func cancelGPTKSetup() {
        gptkSetupTask?.cancel()
    }

    func importWine(_ url: URL) async {
        await perform(L("正在验证并导入 Wine…")) {
            let runtime = try await self.wineImporter.importRuntime(from: url)
            self.wineRuntimes = await self.wineImporter.installed()
            self.status = L("Wine \(runtime.manifest.version) 已导入")
        }
    }

    func importRenderer(_ kind: RendererKind, from url: URL) async {
        await perform(L("正在导入 \(kind.rawValue)…")) {
            let overlay = try await self.overlayImporter.importOverlay(kind, from: url)
            self.rendererOverlays = await self.overlayImporter.installed()
            self.status = L("\(overlay.kind.rawValue) \(overlay.version) 已导入")
        }
    }

    func play(_ game: GameRecord) async {
        await perform(L("正在准备 \(game.displayName)…")) {
            guard let runtime = self.gamingWineRuntime else {
                throw IndieError.notFound(L("请先准备 Portlane Wine 11 开源运行环境"))
            }
            let provider = WineRuntimeProvider(manifest: runtime.manifest, root: runtime.root)
            let bottle: BottleRecord
            if let bottleID = game.bottleID, let existing = self.bottles.first(where: { $0.id == bottleID }) {
                bottle = existing
            } else {
                bottle = try await BottleManager(paths: self.paths, store: self.store).create(name: game.displayName, runtime: provider)
                var updated = game
                updated.bottleID = bottle.id
                try await self.store.saveGame(updated)
                self.games = try await self.store.games()
                self.bottles = try await self.store.bottles()
            }
            var rendererSet: Set<RendererKind> = [.wineD3D]
            var overlays: [RendererKind: URL] = [:]
            if let metal = self.preferredD3DMetal, let renderer = metal.rendererRoot {
                rendererSet.insert(.d3dMetal)
                overlays[.d3dMetal] = renderer.appendingPathComponent("wine", isDirectory: true)
            }
            for overlay in self.rendererOverlays where overlays[overlay.kind] == nil {
                rendererSet.insert(overlay.kind)
                overlays[overlay.kind] = overlay.root
            }
            let configuration = self.configuration(for: game)
            await provider.stopBottle(bottle)
            try await provider.configureControllerSupport(in: bottle)
            let recipe = self.recipeRepository.match(game.analysis)
            let renderer = try RendererResolver.resolve(
                analysis: game.analysis,
                preferred: configuration.preferredRenderer,
                recipe: recipe,
                installed: InstalledRenderers(available: rendererSet, overlayPaths: overlays)
            ).renderer
            let recipeProfile = recipe?.profiles.first { $0.renderer == renderer }
            let wantsHUD = configuration.metalHUD.resolve(
                default: UserDefaults.standard.bool(forKey: "metalHUD")
            )
            let metalHUD = wantsHUD && [.d3dMetal, .dxmt].contains(renderer)
            let metalFX = configuration.metalFX.resolve(
                default: UserDefaults.standard.bool(forKey: "metalFX")
            ) && renderer == .d3dMetal && recipeProfile?.metalFX != false
            let defaultMetal4 = UserDefaults.standard.object(forKey: "metal4") as? Bool ?? true
            let metal4 = configuration.metal4.resolve(default: defaultMetal4) &&
                renderer == .d3dMetal && recipeProfile?.metal4 != false && Self.supportsMetal4
            var environment = ControllerLaunchEnvironment.make(
                mode: configuration.controllerMode,
                rumble: configuration.controllerRumble
            )
            if renderer == .d3dMetal {
                guard let component = self.preferredD3DMetal,
                      let rendererRoot = component.rendererRoot else {
                    throw IndieError.notFound(L("请先使用“一键安装 GPTK 4”导入 D3DMetal"))
                }
                try D3DMetalRendererPreparer.installBridge(
                    rendererRoot: rendererRoot, version: component.version, bottle: bottle
                )
                if metalFX {
                    try D3DMetalRendererPreparer.enableMetalFX(
                        rendererRoot: rendererRoot, version: component.version, bottle: bottle
                    )
                }
                let metalEnvironment = try D3DMetalLaunchEnvironment.make(
                    rendererRoot: rendererRoot,
                    runtimeRoot: runtime.root,
                    metalHUD: metalHUD,
                    metalFX: metalFX,
                    metal4: metal4
                )
                environment.merge(metalEnvironment) { current, _ in current }
            } else if renderer == .wineD3D {
                try await provider.configureWineD3DGraphics(in: bottle)
            }
            environment.merge(SpatialAudioDiagnostics.environment(
                enabled: configuration.spatialAudioDiagnostics == true
            )) { _, configured in configured }
            let profile = LaunchProfile(
                runtimeID: runtime.manifest.id,
                preferredRenderer: renderer,
                syncBackend: configuration.syncBackend,
                arguments: configuration.arguments,
                environment: environment,
                metalHUD: metalHUD,
                virtualDesktop: configuration.virtualDesktop
            )
            let basePlan = try LaunchPlanBuilder.build(
                executable: game.executableURL, bottle: bottle, profile: profile,
                analysis: game.analysis, recipe: recipe,
                installed: InstalledRenderers(available: rendererSet, overlayPaths: overlays)
            )
            let plan = basePlan.withEnvironment(try GameCompatibilityEnvironment.applying(configuration, to: basePlan.environment))
            try self.paths.createDirectories()
            let log = self.paths.logs.appendingPathComponent("\(plan.id.uuidString).log")
            self.status = L("正在运行 \(game.displayName)…")
            let session = await provider.launch(plan, logURL: log)
            try await self.store.saveSession(session)
            self.status = L("游戏已退出：\(String(describing: session.result))")
        }
    }

    func configuration(for game: SteamGame) -> GameConfiguration {
        configuration(appID: game.appID)
    }

    func configuration(appID: UInt64) -> GameConfiguration {
        let fallback = defaultGameConfiguration(id: GameConfiguration.steam(appID: appID).id)
        return gameConfigurations[fallback.id] ?? fallback
    }

    func configuration(for game: GameRecord) -> GameConfiguration {
        let fallback = defaultGameConfiguration(id: GameConfiguration.local(gameID: game.id).id)
        return gameConfigurations[fallback.id] ?? fallback
    }

    func defaultGameConfiguration(id: String) -> GameConfiguration {
        let rawMode = UserDefaults.standard.string(forKey: "defaultControllerMode")
        let mode = rawMode.flatMap(ControllerMode.init(rawValue:)) ?? .automatic
        let rumble = UserDefaults.standard.object(forKey: "defaultControllerRumble") as? Bool ?? true
        return GameConfiguration(id: id, controllerMode: mode, controllerRumble: rumble)
    }

    func saveGameConfiguration(_ configuration: GameConfiguration) async {
        lastError = nil
        do {
            try GameCompatibilityEnvironment.validate(configuration)
            guard configuration.virtualDesktop?.isValid != false else {
                throw IndieError.invalidArgument(L("分辨率必须在 640×480 到 7680×4320 之间"))
            }
            var updated = configuration
            updated.updatedAt = Date()
            try await store.saveGameConfiguration(updated)
            gameConfigurations[updated.id] = updated
            status = L("游戏设置已保存")
        } catch { present(error) }
    }

    private func perform(_ initialStatus: String, operation: @escaping @MainActor () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        lastError = nil
        status = initialStatus
        defer { isWorking = false }
        do { try await operation() }
        catch is CancellationError { status = L("已取消 GPTK 安装") }
        catch { present(error) }
    }

    private func setupLatestGPTK() async {
        isGPTKSetupRunning = true
        defer { isGPTKSetupRunning = false }
        await perform(L("正在从下载服务器安装 GPTK 4…")) {
            self.status = L("正在下载并校验 GPTK 4（约 26.5 MB）…")
            let image = try await GPTKDownloadService(paths: self.paths).download()
            self.status = L("正在验证 Apple 签名并安装 GPTK 4…")
            let component = try await self.importer.importFromAppleImage(image)
            self.d3dMetal = try await self.importer.installedComponents()
            let version = component.version.split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) } ?? 0
            guard version >= 4 else {
                throw IndieError.invalidData(L("下载的 D3DMetal 版本是 \(component.version)，不是 GPTK 4"))
            }
            guard component.rendererRoot != nil else {
                throw IndieError.invalidData(L("GPTK 4 镜像缺少 D3DMetal Wine Bridge；请确认下载的是 Windows 游戏评估环境"))
            }
            self.status = L("正在安装支持现代 Steam 的 Portlane Wine 11（约 50 MB）…")
            _ = try await self.communityGamingWine.installLatest()
            self.wineRuntimes = await self.wineImporter.installed()
            self.status = L("GPTK \(component.version) 已验证并安装，可以启动游戏")
        }
    }

    private static func majorVersion(_ value: String) -> Int {
        value.split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) } ?? 0
    }

    private func present(_ error: Error) {
        lastError = error.localizedDescription
        status = L("操作失败")
    }

    private func scanDefaultSteamLibrary(force: Bool = true) async throws {
        guard let bottle = steamBottle else { return }
        let snapshot = try await steamLibraryReader.read(
            steamRoot: SteamCompatibilityManager.steamRoot(in: bottle), bottleRoot: bottle.root, force: force)
        guard steamBottle?.id == bottle.id, !Task.isCancelled else { return }
        if !steamMetadataCacheLoaded {
            let cacheURL = paths.steamCatalogCache
            if steamMetadataCacheLoadTask == nil {
                steamMetadataCacheLoadTask = Task.detached(priority: .utility) {
                    SteamStoreMetadataCache.load(from: cacheURL)
                }
            }
            let cached = await steamMetadataCacheLoadTask?.value ?? [:]
            if !steamMetadataCacheLoaded {
                steamMetadataCache = cached
                steamMetadataCacheLoaded = true
                steamMetadataCacheLoadTask = nil
            }
        }
        let records = snapshot.records
        let playable = records.filter {
            SteamDownloadBridge.permitsPlay(manifestReady: snapshot.readyAppIDs.contains($0.appID), download: steamBridgeDownloads[$0.appID])
        }
        let downloading = records.filter {
            !SteamDownloadBridge.permitsPlay(manifestReady: snapshot.readyAppIDs.contains($0.appID), download: steamBridgeDownloads[$0.appID]) && $0.appID != 228980
        }
        if steamGames != playable { steamGames = playable }
        if steamDownloads != downloading { steamDownloads = downloading }
        var accountGames = snapshot.accountGames
        for index in accountGames.indices {
            guard let metadata = steamMetadataCache[accountGames[index].appID] else { continue }
            accountGames[index].name = metadata.name
            accountGames[index].headerImageURL = metadata.headerImageURL
            accountGames[index].description = metadata.description
        }
        if steamAccountGames != accountGames { steamAccountGames = accountGames }
        if steamActivities != snapshot.activities { steamActivities = snapshot.activities }
        if steamLibraries != snapshot.libraries { steamLibraries = snapshot.libraries }
        // The official Steam library owns artwork and account browsing. The
        // Mac configuration selector needs only locally installed game names.
    }

    func syncSteamLibrary() async {
        guard !onboardingBusy, !isWorking else { return }
        pollSteamDownloads()
        do {
            try await scanDefaultSteamLibrary(force: false)
            if !steamAccountGames.isEmpty {
                status = L("已同步 \(steamAccountGames.count) 款账户游戏")
            } else {
                status = L("正在等待 Steam 写入账户游戏库…")
            }
        } catch {
            status = L("游戏库同步失败：\(error.localizedDescription)")
        }
    }

    private func scheduleSteamMetadataHydration() {
        guard steamMetadataTask == nil else { return }
        let appIDs = steamAccountGames
            .filter { steamMetadataCache[$0.appID] == nil && steamMetadataRetry.canAttempt($0.appID) }
            .map(\.appID)
        guard !appIDs.isEmpty else { return }
        isSteamMetadataLoading = true
        steamMetadataTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.steamMetadataTask = nil
                self.isSteamMetadataLoading = false
            }
            for offset in stride(from: 0, to: appIDs.count, by: 8) {
                if Task.isCancelled { return }
                let chunk = Array(appIDs[offset..<min(offset + 8, appIDs.count)])
                let metadata = await withTaskGroup(of: (UInt64, SteamStoreMetadataService.Metadata?).self) { group in
                    for appID in chunk {
                        group.addTask { (appID, await SteamStoreMetadataService.fetch(appID: appID)) }
                    }
                    var values: [(UInt64, SteamStoreMetadataService.Metadata?)] = []
                    for await value in group { values.append(value) }
                    return values
                }
                guard !Task.isCancelled else { return }
                for (appID, details) in metadata {
                    guard let details else {
                        self.steamMetadataRetry.failed(appID)
                        continue
                    }
                    self.steamMetadataRetry.succeeded(appID)
                    guard let index = self.steamAccountGames.firstIndex(where: { $0.appID == appID }) else { continue }
                    self.steamAccountGames[index].name = details.name
                    self.steamAccountGames[index].headerImageURL = details.headerImageURL
                    self.steamAccountGames[index].description = details.description
                    self.steamMetadataCache[appID] = details
                }
                let cache = self.steamMetadataCache
                let cacheURL = self.paths.steamCatalogCache
                await Task.detached(priority: .utility) {
                    try? SteamStoreMetadataCache.save(cache, to: cacheURL)
                }.value
            }
        }
    }

    private func sendSteamURI(_ uri: String, status initialStatus: String, completion: String? = nil,
                              showWindow: Bool = true) async {
        guard !isOpeningSteamClient else { return }
        guard !isWorking else {
            steamClientNotice = L("正在处理其他操作，请稍后打开 Steam 客户端");
            return
        }
        isOpeningSteamClient = true
        steamClientNotice = initialStatus
        defer { isOpeningSteamClient = false }
        await perform(initialStatus) {
            guard let runtime = self.gamingWineRuntime,
                  let bottle = self.steamBottle, let steam = self.steamExecutable else {
                throw IndieError.notFound(L("尚未完成 Steam 安装"))
            }
            let provider = WineRuntimeProvider(manifest: runtime.manifest, root: runtime.root)
            let before = try await SteamClientProcessSnapshot.read(steamExecutable: steam)
            let previous = SteamClientDestination.reusableDescriptor(
                self.steamSessionManager.currentDescriptor, bottleID: bottle.id,
                runtimeID: runtime.manifest.id, processExists: before.hasClients)
            // Never stop Wine or reconfigure its registry for a UI/navigation request.
            // Only repair CEF before a cold launch, when no mapped helper is running.
            if !before.hasClients {
                guard let wrapper = SteamCompatibilityManager.bundledWrapperURL() else {
                    throw IndieError.notFound(L("缺少 Steam 界面兼容组件"))
                }
                _ = try SteamCompatibilityManager.prepare(bottle: bottle, wrapper: wrapper,
                                                         steamDirectory: steam.deletingLastPathComponent())
            }
            let environment = previous?.environment ?? [
                "LANG": "zh_CN.UTF-8", "LC_ALL": "zh_CN.UTF-8", "WINEDEBUG": "-all",
                "WINEDLLOVERRIDES": "mscoree,mshtml=;winedbg.exe=d;dxgi,d3d10,d3d10core,d3d11,d3d12=b"
            ]
            let profile = LaunchProfile(runtimeID: runtime.manifest.id, preferredRenderer: .wineD3D,
                syncBackend: environment["WINEMSYNC"] == "1" ? .msync : .wineserver,
                arguments: SteamCompatibilityManager.launchArguments(silent: !showWindow) + (uri.isEmpty ? [] : [uri]),
                environment: environment)
            let plan = try LaunchPlanBuilder.build(executable: steam,
                windowsExecutablePath: try WinePath.windowsPath(for: steam, in: bottle),
                bottle: bottle, profile: profile,
                analysis: .init(identity: .init(executableName: "steam.exe"), architecture: .x86_64,
                                directX: .none, antiCheat: .none, importedLibraries: []),
                recipe: nil, installed: .init(available: [.wineD3D]))
            let log = self.paths.logs.appendingPathComponent("\(plan.id)-steam-client.log")
            if showWindow || !before.hasClients {
                _ = try await provider.launchDetached(plan, logURL: log)
            }
            // Focus only processes mapped to this exact Steam installation, not other bottles/games.
            var after = try await SteamClientProcessSnapshot.read(steamExecutable: steam)
            for _ in 0..<4 where after.steamPIDs.isEmpty {
                try await Task.sleep(for: .milliseconds(400))
                after = try await SteamClientProcessSnapshot.read(steamExecutable: steam)
            }
            if !after.steamPIDs.isEmpty {
                self.steamSessionManager.didLaunch(previous ?? .init(bottleID: bottle.id,
                    runtimeID: runtime.manifest.id, environment: plan.environment, virtualDesktop: nil),
                    reused: previous != nil)
            } else {
                self.steamSessionManager.didStop()
            }
            for attempt in 0..<(showWindow ? 12 : 0) {
                if attempt == 0, let bridge = self.downloadBridge() { try? await bridge.fitClientWindow() }
                if SteamClientActivation.show(after) { break }
                if attempt == 11 { break }
                try await Task.sleep(for: .milliseconds(500))
                after = try await SteamClientProcessSnapshot.read(steamExecutable: steam)
            }
            self.status = completion ?? (showWindow ? "" : L("正在连接 Steam 后台…"))
            self.steamClientNotice = self.status.isEmpty ? nil : self.status
        }
        if lastError != nil { steamClientNotice = L("未能打开 Steam 客户端，请检查错误提示后重试") }
        await syncSteamLibrary()
    }
}
