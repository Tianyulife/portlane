import AppKit
import IndieCore
import SwiftUI

/// Shared opaque surfaces for the app's windows, sheets and settings panels.
struct SteamSettingsSection<Content: View>: View {
    private let title: String?
    private let content: Content
    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title { Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(IndiePalette.blue) }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(18)
        .background(IndiePalette.panel, in: RoundedRectangle(cornerRadius: 3))
    }
}

struct SteamButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(configuration.role == .destructive ? Color(red: 0.96, green: 0.54, blue: 0.51) : Color.white.opacity(enabled ? 0.9 : 0.4))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(prominent ? IndiePalette.primary : IndiePalette.control, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(IndiePalette.border))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct SteamWindowSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SurfaceView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class SurfaceView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isOpaque = true
            window?.backgroundColor = NSColor(red: 0.106, green: 0.157, blue: 0.220, alpha: 1)
            window?.appearance = NSAppearance(named: .darkAqua)
            window?.titlebarAppearsTransparent = true
        }
    }
}

extension View {
    func steamSurface() -> some View {
        self.background(IndiePalette.canvas)
            .background(SteamWindowSurface().frame(width: 0, height: 0))
            .preferredColorScheme(.dark)
            .tint(IndiePalette.blue)
            .toggleStyle(SteamToggleStyle())
            .buttonStyle(SteamButtonStyle())
    }

    func steamDialog<Actions: View, Message: View>(_ title: String, isPresented: Binding<Bool>,
        @ViewBuilder actions: @escaping () -> Actions,
        @ViewBuilder message: @escaping () -> Message = { EmptyView() }
    ) -> some View {
        self.sheet(isPresented: isPresented) {
            VStack(alignment: .leading, spacing: 20) {
                Text(title).font(.system(size: 20, weight: .medium))
                message().foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 10) { Spacer(); actions() }
            }
            .padding(24).frame(width: 480, alignment: .leading)
            .steamSurface().presentationBackground(IndiePalette.canvas)
            .onExitCommand { isPresented.wrappedValue = false }
        }
    }
}

struct SteamPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let choices: [(String, Value)]
    @State private var expanded = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        HStack(spacing: 14) {
            if !title.isEmpty { Text(title) }
            Button { expanded.toggle() } label: {
                HStack {
                    Text(choices.first { $0.1 == selection }?.0 ?? "").lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(IndiePalette.blue)
                }.padding(.horizontal, 12).padding(.vertical, 8)
                    .background(IndiePalette.control, in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(IndiePalette.border))
            }.buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(choices.first { $0.1 == selection }?.0 ?? "")
                .popover(isPresented: $expanded, arrowEdge: .bottom) {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(choices.indices, id: \.self) { index in
                                Button { selection = choices[index].1; expanded = false } label: {
                                    HStack {
                                        Text(choices[index].0).multilineTextAlignment(.leading)
                                        Spacer()
                                        if choices[index].1 == selection { Image(systemName: "checkmark").foregroundStyle(IndiePalette.blue) }
                                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(choices[index].1 == selection ? IndiePalette.control : IndiePalette.panel)
                                }.buttonStyle(.plain)
                            }
                        }.padding(6)
                    }.frame(width: 320).frame(maxHeight: min(360, CGFloat(choices.count) * 48 + 12))
                        .steamSurface().presentationBackground(IndiePalette.panel)
                }
        }.opacity(enabled ? 1 : 0.45)
    }
}

struct SteamToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? IndiePalette.blue : IndiePalette.secondaryText)
                    .font(.system(size: 17)).accessibilityHidden(true)
                configuration.label
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityValue(configuration.isOn ? L("开启") : L("关闭"))
    }
}

struct SteamMenuAction {
    let title: String
    let action: () -> Void
}

struct SteamActionMenu: View {
    let title: String
    var systemImage: String? = nil
    let actions: [SteamMenuAction]
    @State private var expanded = false
    var body: some View {
        Button { expanded.toggle() } label: {
            if let systemImage { Image(systemName: systemImage) } else { Text(title) }
        }.accessibilityLabel(title)
            .popover(isPresented: $expanded, arrowEdge: .bottom) {
                VStack(spacing: 2) {
                    ForEach(actions.indices, id: \.self) { index in
                        Button {
                            expanded = false
                            // Close the popover before presenting an import dialog.
                            Task { @MainActor in
                                await Task.yield()
                                actions[index].action()
                            }
                        } label: {
                            Text(actions[index].title).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(IndiePalette.panel)
                        }.buttonStyle(.plain)
                    }
                }.padding(6).frame(width: 280).steamSurface().presentationBackground(IndiePalette.panel)
            }
    }
}
