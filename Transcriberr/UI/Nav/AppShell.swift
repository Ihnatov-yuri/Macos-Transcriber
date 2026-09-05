import SwiftUI

/// Top-level shell. Fixed-width sidebar on the left + adaptive detail pane
/// on the right. No NavigationSplitView — that gave us draggable dividers
/// and double-nesting problems. A plain `HStack` keeps the sidebar
/// non-resizable and ensures every section button is reliably hittable.
struct AppShell: View {
    enum Section: String, CaseIterable, Identifiable, Hashable {
        case record, library, settings
        var id: String { rawValue }
        var label: String {
            switch self {
            case .record:   return "RECORD"
            case .library:  return "LIBRARY"
            case .settings: return "SETTINGS"
            }
        }
        var index: Int {
            switch self {
            case .record:   return 2
            case .library:  return 1
            case .settings: return 4
            }
        }
    }

    @Environment(AppContainer.self) private var container
    @State private var section: Section = .library
    /// The Record screen's model lives here, for the app's lifetime — see
    /// RecordView.model for why a view-scoped one lost in-flight recordings.
    @State private var recordModel: RecordModel?
    private let sidebarWidth: CGFloat = 200

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)
                .background(AppColor.paperEdge)

            Rectangle().fill(AppColor.hairline).frame(width: 1)

            Group {
                switch section {
                case .record:
                    if let recordModel {
                        RecordView(model: recordModel)
                    } else {
                        Sheet { ProgressView().padding() }
                    }
                case .library:  LibraryView()
                case .settings: SettingsScreen()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColor.paper)
        }
        .background(AppColor.paper)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // File → New Recording (⌘N): bring the Record section forward;
        // RecordView picks up the pending request and starts recording.
        .onChange(of: container.newRecordingRequested) { _, _ in
            section = .record
        }
        .task {
            if recordModel == nil { recordModel = RecordModel(container: container) }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 36)   // leaves room for the traffic lights

            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text("transcriberr")
                    .font(AppFont.saira(20, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(AppColor.ink)
                Circle()
                    .fill(AppColor.accent)
                    .frame(width: 7, height: 7)
                    .offset(y: -2)
                Spacer()
            }
            .padding(.horizontal, AppMetric.l)
            .padding(.bottom, 20)

            InkRule()

            ForEach(Section.allCases) { s in
                sidebarRow(s)
                HairlineSoft()
            }

            Spacer(minLength: 0)

            HairlineSoft()
            HStack {
                Text(Bundle.versionBadge).monoLabel(9, color: AppColor.inkMuted)
                Spacer()
            }
            .padding(.horizontal, AppMetric.l)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func sidebarRow(_ s: Section) -> some View {
        TapButton {
            section = s
        } label: {
            HStack(alignment: .center, spacing: AppMetric.s) {
                Text(String(format: "%02d", s.index))
                    .monoLabel(11, color: section == s ? AppColor.accent : AppColor.inkMuted)
                Text(s.label)
                    .monoLabel(11, color: section == s ? AppColor.ink : AppColor.inkSoft)
                Spacer()
                if section == s {
                    Rectangle().fill(AppColor.accent).frame(width: 3, height: 16)
                }
            }
            .padding(.horizontal, AppMetric.l)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(section == s ? AppColor.paper : Color.clear)
            .contentShape(Rectangle())
        }

    }
}


extension Bundle {
    /// "V1·5·1 / MACOS" — always the real bundle version, so the sidebar
    /// badge can never lie about which build is running.
    static var versionBadge: String {
        let v = main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "V\(v.replacingOccurrences(of: ".", with: "·")) / MACOS"
    }
}
