import IndieCore
import SwiftUI

struct GameSettingsTarget: Identifiable {
    let id: String
    let name: String
    let detail: String
    let configuration: GameConfiguration
}

private enum RendererChoice: String, CaseIterable, Identifiable {
    case automatic, d3dMetal, dxmt, dxvk, wineD3D, vkd3d
    var id: String { rawValue }

    init(_ renderer: RendererKind?) {
        switch renderer {
        case .d3dMetal: self = .d3dMetal
        case .dxmt: self = .dxmt
        case .dxvk: self = .dxvk
        case .wineD3D: self = .wineD3D
        case .vkd3d: self = .vkd3d
        case nil: self = .automatic
        }
    }

    var renderer: RendererKind? {
        switch self {
        case .automatic: nil
        case .d3dMetal: .d3dMetal
        case .dxmt: .dxmt
        case .dxvk: .dxvk
        case .wineD3D: .wineD3D
        case .vkd3d: .vkd3d
        }
    }

    var label: String {
        switch self {
        case .automatic: L("自动（推荐）")
        case .d3dMetal: "D3DMetal"
        case .dxmt: "DXMT"
        case .dxvk: "DXVK"
        case .wineD3D: "WineD3D"
        case .vkd3d: "VKD3D"
        }
    }
}

struct GameSettingsView: View {
    @EnvironmentObject private var model: MacGamingUncleAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    let target: GameSettingsTarget

    let embedded: Bool
    @Binding private var hasUnsavedChanges: Bool
    @State private var category = 0
    @State private var environmentLines: String
    @State private var dllRows: [DLLSettingRow]
    @State private var isSaving = false
    @State private var saved = false

    private var steamAppID: UInt64? { target.id.hasPrefix("steam:") ? UInt64(target.id.dropFirst(6)) : nil }

    @State private var configuration: GameConfiguration
    @State private var useVirtualDesktop: Bool
    @State private var width: String
    @State private var height: String
    @State private var renderer: RendererChoice
    @State private var argumentLines: String

    init(target: GameSettingsTarget, embedded: Bool = false, hasUnsavedChanges: Binding<Bool> = .constant(false)) {
        self.target = target
        self.embedded = embedded
        _hasUnsavedChanges = hasUnsavedChanges
        _environmentLines = State(initialValue: (target.configuration.environmentVariables ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
        _dllRows = State(initialValue: (target.configuration.dllOverrides ?? [:]).sorted { $0.key < $1.key }.map { DLLSettingRow(name: $0.key, order: $0.value) })
        let resolution = target.configuration.virtualDesktop
        _configuration = State(initialValue: target.configuration)
        _useVirtualDesktop = State(initialValue: resolution != nil)
        _width = State(initialValue: String(resolution?.width ?? 1920))
        _height = State(initialValue: String(resolution?.height ?? 1080))
        _renderer = State(initialValue: RendererChoice(target.configuration.preferredRenderer))
        _argumentLines = State(initialValue: target.configuration.arguments.joined(separator: "\n"))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(target.name).font(.system(size: 20, weight: .medium))
                    Text(target.detail).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("恢复推荐")) { reset() }.disabled(isSaving)
                if !embedded { Button(L("取消")) { dismiss() }.disabled(isSaving) }
                Button(L("保存")) { save() }.buttonStyle(SteamButtonStyle(prominent: true)).keyboardShortcut(.defaultAction).disabled(isSaving)

            }
            .padding(24)
            Divider()

            HStack(spacing: 24) {
                categoryButton(L("图形与性能"), value: 0)
                categoryButton(L("兼容规则"), value: 1)
                categoryButton(L("输入与音频"), value: 2)
                Spacer()
            }.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
            ScrollView {
              VStack(alignment: .leading, spacing: 14) {
                if category == 0 {
                SteamSettingsSection(title: L("通用插帧（实验）")) {
                    Button(L("打开插帧面板")) {
                        openWindow(id: "frame-interpolation", value: target.id)
                    }
                    Text(L("无需游戏支持 DLSS。开启一次后自动跟随游戏窗口，默认关闭；不改变分辨率或鼠标坐标。需要 macOS 26。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                SteamSettingsSection(title: L("显示")) {
                    Toggle(L("使用 Wine 虚拟桌面"), isOn: $useVirtualDesktop)
                    Text(L("为这个游戏创建固定尺寸的 Windows 桌面，可避免 Retina 缩放导致的画面拉伸和鼠标错位。"))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField(L("宽度"), text: $width).frame(width: 100)
                        Text("×").foregroundStyle(.secondary)
                        TextField(L("高度"), text: $height).frame(width: 100)
                        Text(L("像素")).foregroundStyle(.secondary)
                        Spacer()
                        SteamActionMenu(title: L("常用分辨率"), actions: [(1280, 720), (1600, 900), (1920, 1080), (2560, 1440), (3840, 2160)].map { w, h in
                            .init(title: "\(w) × \(h)", action: { width = String(w); height = String(h) })
                        })
                    }
                    .disabled(!useVirtualDesktop)
                }

                SteamSettingsSection(title: L("图形")) {
                    SteamPicker(title: L("渲染后端"), selection: $renderer, choices: rendererChoices.map { ($0.label, $0) })
                    SteamPicker(title: L("同步方式"), selection: $configuration.syncBackend, choices: [(L("自动（推荐）"), .automatic), ("MSync", .msync), ("Wine Server", .wineserver)])
                    overridePicker("Apple Metal HUD", selection: $configuration.metalHUD)
                    overridePicker("MetalFX / DLSS", selection: $configuration.metalFX)
                    overridePicker("Metal 4", selection: $configuration.metal4)
                }

                }
                if category == 1 {
                    SteamSettingsSection(title: L("DLL 加载规则")) {
                        if steamAppID == 2358720 {
                            HStack { Text("mscoree").font(.system(.body, design: .monospaced)); Spacer(); Text(L("推荐：Wine 内置")).foregroundStyle(IndiePalette.green) }
                            Text(L("黑神话：悟空需要此 DLL。恢复推荐会保留已验证的内置兼容规则。"))
                                .font(.caption).foregroundStyle(.secondary)
                        } else { Text(L("未覆盖的 DLL 使用渲染组件与内置兼容规则。")).font(.caption).foregroundStyle(.secondary) }
                        ForEach($dllRows) { $row in
                            HStack {
                                TextField(L("DLL 名称"), text: $row.name).frame(maxWidth: 220)
                                SteamPicker(title: L("加载方式"), selection: $row.order, choices: [(L("Wine 内置"), .builtin), (L("原生优先"), .nativeFirst), (L("内置优先"), .builtinFirst), (L("禁用"), .disabled)])
                                Button(L("移除"), systemImage: "minus.circle") { dllRows.removeAll { $0.id == row.id } }.labelStyle(.iconOnly)
                            }
                        }
                        Button(L("添加 DLL 覆盖"), systemImage: "plus") { dllRows.append(DLLSettingRow()) }
                    }
                    SteamSettingsSection {
                        DisclosureGroup(L("高级：自定义环境变量")) {
                            TextEditor(text: $environmentLines).scrollContentBackground(.hidden).padding(8).background(IndiePalette.control).font(.system(.body, design: .monospaced)).frame(minHeight: 90)
                            Text(L("每行 NAME=VALUE；仅作用于当前游戏。Bottle 路径和 Steam 游戏身份由管理器保留。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let appID = steamAppID {
                        SteamSettingsSection(title: L("游戏启动参数")) {
                            Button(L("打开 Steam 游戏属性"), systemImage: "arrow.up.forward.app") { Task { await model.openSteamGameProperties(appID: appID) } }
                            Text(L("启动参数由官方 Steam 管理。Mac 兼容设置在启动前自动应用。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        SteamSettingsSection(title: L("启动参数")) {
                            TextEditor(text: $argumentLines).scrollContentBackground(.hidden).padding(8).background(IndiePalette.control).font(.system(.body, design: .monospaced)).frame(minHeight: 70)
                            Text(L("每行一个参数；仅应用于这个游戏。")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if category == 2 {
                SteamSettingsSection(title: L("手柄")) {
                    SteamPicker(title: L("输入模式"), selection: $configuration.controllerMode, choices: [(L("自动（Wine / Steam Input）"), .automatic), (L("增强兼容（SDL HIDAPI）"), .enhanced)])
                    Toggle(L("启用手柄震动"), isOn: $configuration.controllerRumble)
                        .disabled(configuration.controllerMode != .enhanced)
                    ControllerConnectionSummary(manager: model.controllerManager)
                    Text(L("Xbox、PlayStation、Switch Pro 及标准 USB/蓝牙手柄由 macOS 检测，再交给 Wine；部分 Steam 游戏仍需在 Steam 中启用 Steam Input。"))
                        .font(.caption).foregroundStyle(.secondary)
                }

                SteamSettingsSection(title: L("音频诊断")) {
                    Toggle(L("记录空间音频诊断日志"), isOn: Binding(
                        get: { configuration.spatialAudioDiagnostics == true },
                        set: { configuration.spatialAudioDiagnostics = $0 ? true : nil }
                    ))
                    Text(L("用于确认游戏是否提交空间音频对象。日志会增加运行开销；短时测试结束后关闭，并重新启动游戏。"))
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let appID = steamAppID {
                    SteamSettingsSection(title: L("Steam Input")) {
                        Button(L("在 Steam 中管理按键映射"), systemImage: "arrow.up.forward.app") { Task { await model.openSteamGameProperties(appID: appID) } }
                    }
                }
                }
            }
              .padding(.horizontal, 24).padding(.bottom, 20)
            }
            if embedded {
                HStack { Text(saved && !hasUnsavedChanges ? L("已保存 · 下次启动生效") : hasUnsavedChanges ? L("有未保存的修改") : L("设置仅作用于当前游戏 · 下次启动生效")); Spacer() }
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 12)
            }
        }
        .frame(minWidth: embedded ? 0 : 660, minHeight: embedded ? 0 : 680)
        .steamSurface()
        .onChange(of: configuration) { _, _ in hasUnsavedChanges = true; saved = false }
        .onChange(of: renderer) { _, _ in hasUnsavedChanges = true; saved = false }
        .onChange(of: useVirtualDesktop) { _, _ in hasUnsavedChanges = true; saved = false }
        .onChange(of: width) { _, _ in hasUnsavedChanges = true; saved = false }
        .onChange(of: height) { _, _ in hasUnsavedChanges = true; saved = false }
        .onChange(of: argumentLines) { _, _ in hasUnsavedChanges = true; saved = false }
        .onChange(of: environmentLines) { _, _ in hasUnsavedChanges = true; saved = false }
        .onChange(of: dllRows) { _, _ in hasUnsavedChanges = true; saved = false }
        .onChange(of: model.gameConfigurations[target.id]?.frameInterpolation) { _, value in
            configuration.frameInterpolation = value
        }
    }

    private func categoryButton(_ title: String, value: Int) -> some View {
        Button { category = value } label: {
            VStack(spacing: 10) {
                Text(title).font(.system(size: 14, weight: .medium))
                    .foregroundStyle(category == value ? IndiePalette.blue : IndiePalette.secondaryText)
                Rectangle().fill(category == value ? IndiePalette.blue : .clear).frame(height: 2)
            }.fixedSize(horizontal: true, vertical: false)
        }.buttonStyle(.plain)
    }

    private var rendererChoices: [RendererChoice] {
        RendererChoice.allCases.filter { choice in
            choice == .automatic || choice == renderer ||
                choice.renderer.map(model.availableRendererKinds.contains) == true
        }
    }

    @ViewBuilder
    private func overridePicker(_ title: String, selection: Binding<GameSettingOverride>) -> some View {
        SteamPicker(title: title, selection: selection, choices: [(L("跟随全局设置"), .inherit), (L("开启"), .enabled), (L("关闭"), .disabled)])
    }

    private func save() {
        var draft = configuration
        draft.virtualDesktop = useVirtualDesktop ? GameResolution(width: Int(width) ?? 0, height: Int(height) ?? 0) : nil
        draft.preferredRenderer = renderer.renderer
        if steamAppID == nil {
            draft.arguments = argumentLines.split(whereSeparator: \Character.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        var overrides: [String: DLLLoadOrder] = [:]
        for row in dllRows where !row.name.trimmingCharacters(in: .whitespaces).isEmpty {
            let name = row.name.trimmingCharacters(in: .whitespaces).lowercased()
            guard overrides[name] == nil else { model.lastError = L("DLL 名称不能重复：\(name)"); return }
            overrides[name] = row.order
        }
        var variables: [String: String] = [:]
        for line in environmentLines.split(whereSeparator: \Character.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { model.lastError = L("环境变量需要使用 NAME=VALUE 格式"); return }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard variables[name] == nil else { model.lastError = L("环境变量名称不能重复：\(name)"); return }
            variables[name] = String(line[line.index(after: equals)...])
        }
        draft.dllOverrides = overrides.isEmpty ? nil : overrides
        draft.environmentVariables = variables.isEmpty ? nil : variables
        isSaving = true
        Task {
            await model.saveGameConfiguration(draft)
            isSaving = false
            if model.lastError == nil {
                hasUnsavedChanges = false; saved = true
                if !embedded { dismiss() }
            }
        }
    }

    private func reset() {
        configuration = model.defaultGameConfiguration(id: target.id)
        useVirtualDesktop = false
        width = "1920"
        height = "1080"
        renderer = .automatic
        argumentLines = ""
        dllRows = []
        environmentLines = ""
    }
}

private struct DLLSettingRow: Identifiable, Equatable {
    let id = UUID()
    var name = ""
    var order = DLLLoadOrder.builtin
}
