import AppKit
import IndieCore
import SwiftUI

struct GameLaunchProgressView: View {
    @EnvironmentObject private var model: MacGamingUncleAppModel
    @State private var selectedAppID: UInt64?
    @State private var expanded = true
    private var reports: [GameLaunchReport] {
        model.gameLaunchReports.values.sorted { $0.startedAt > $1.startedAt }
    }
    private var report: GameLaunchReport? {
        reports.first { $0.appID == selectedAppID } ?? reports.first
    }

    var body: some View {
        if let report {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if report.state == .preparing || report.state == .waiting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: report.state == .failed || report.state == .unconfirmed
                              ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(report.state == .failed || report.state == .unconfirmed ? Color.orange : IndiePalette.green)
                    }
                    Text(report.name).font(.headline)
                    Text(L("启动进度")).font(.caption).foregroundStyle(IndiePalette.secondaryText)
                    Spacer()
                    TimelineView(.periodic(from: report.startedAt, by: 1)) { context in
                        let end = report.state == .preparing || report.state == .waiting
                            ? context.date : (report.steps.last?.date ?? report.startedAt)
                        Text("\(max(0, Int(end.timeIntervalSince(report.startedAt))))s")
                            .font(.caption).monospacedDigit().foregroundStyle(IndiePalette.secondaryText)
                    }
                    if reports.count > 1 {
                        Menu(L("其他启动记录")) {
                            ForEach(reports, id: \.appID) { item in
                                Button(item.name) { selectedAppID = item.appID }
                            }
                        }
                    }
                    Button(expanded ? L("收起详情") : L("查看详情")) { expanded.toggle() }
                }
                Text(report.steps.last?.detail ?? "").font(.callout)
                if let error = report.error {
                    Text(error).font(.callout).foregroundStyle(Color.orange).textSelection(.enabled)
                }
                if expanded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(report.steps.enumerated()), id: \.offset) { _, step in
                                HStack(alignment: .top, spacing: 12) {
                                    Text("\(max(0, Int(step.date.timeIntervalSince(report.startedAt))))s")
                                        .monospacedDigit().frame(width: 42, alignment: .trailing)
                                        .foregroundStyle(IndiePalette.secondaryText)
                                    Text(step.detail).textSelection(.enabled)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 130).font(.caption)
                }
                if expanded || report.error != nil {
                    HStack {
                        Button(L("复制启动诊断"), systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report.diagnosticText, forType: .string)
                        }
                        if let url = report.logURL {
                            Button(L("查看启动日志"), systemImage: "doc.text") {
                                if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
                                else { NSWorkspace.shared.open(url.deletingLastPathComponent()) }
                            }
                        }
                        Text(report.startedAt, style: .time).foregroundStyle(IndiePalette.secondaryText)
                    }.font(.caption)
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(IndiePalette.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(IndiePalette.border).frame(height: 1) }
            .onChange(of: reports.first?.startedAt) { _, _ in selectedAppID = nil }
        }
    }
}

/// A single unobtrusive line in the shell footer; detailed history lives in Diagnostics.
struct GameLaunchStatusLine: View {
    @EnvironmentObject private var model: MacGamingUncleAppModel
    let openDiagnostics: () -> Void

    private var report: GameLaunchReport? {
        guard let latest = model.gameLaunchReports.values.max(by: { $0.startedAt < $1.startedAt }) else { return nil }
        switch latest.state {
        case .preparing, .waiting, .failed, .unconfirmed: return latest
        case .running, .idle: return nil
        }
    }

    var body: some View {
        if let report {
            let detail: String = report.steps.last?.detail ?? L("启动进度")
            let caption: String = report.name + " · " + detail
            let diagnosticsTitle: String = L("查看启动诊断")
            let helpText: String = (report.error ?? detail) + " · " + diagnosticsTitle
            Button(action: openDiagnostics) {
                statusLabel(report, caption: caption)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 480, alignment: .trailing)
            .layoutPriority(1)
            .help(helpText)
            .accessibilityLabel(diagnosticsTitle + " · " + caption)
        }
    }

    private func statusLabel(_ report: GameLaunchReport, caption: String) -> some View {
        HStack(spacing: 6) {
            if report.state == .preparing || report.state == .waiting {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
            }
            Text(caption).font(.caption).lineLimit(1).truncationMode(.middle)
        }
    }
}
