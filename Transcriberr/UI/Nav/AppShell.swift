import AppKit
import SwiftUI

/// Top-level shell. Fixed-width sidebar on the left + adaptive detail pane
/// on the right. No NavigationSplitView — that gave us draggable dividers
/// and double-nesting problems. A plain `HStack` keeps the sidebar
/// non-resizable and ensures every section button is reliably hittable.
struct AppShell: View {
    enum Section: String, CaseIterable, Identifiable, Hashable {
        case record, library, dictate, settings
        var id: String { rawValue }
        var label: String {
            switch self {
            case .record:   return "Record"
            case .library:  return "Library"
            case .dictate:  return "Dictate"
            case .settings: return "Settings"
            }
        }
        var index: Int {
            switch self {
            case .record:   return 2
            case .library:  return 1
            case .dictate:  return 3
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

    @State private var askUpdateConsent = false

    var body: some View {
        shell
            .onChange(of: container.dictatePaneRequested) { _, _ in section = .dictate }
            .task {
                // A beat after the window settles, once, until answered.
                guard container.updates.needsConsent else { return }
                try? await Task.sleep(for: .seconds(1.5))
                askUpdateConsent = container.updates.needsConsent
            }
            .alert("Check for new versions?", isPresented: $askUpdateConsent) {
                Button("Check once a day") { container.updates.answerConsent(true) }
                Button("Not now", role: .cancel) { container.updates.answerConsent(false) }
            } message: {
                Text(UpdateChecker.consentExplanation)
            }
    }

    private var shell: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)
                .background(AppColor.baseDeep)

            Rectangle().fill(AppColor.hair).frame(width: 1)

            Group {
                switch section {
                case .record:
                    if let recordModel {
                        RecordView(model: recordModel)
                    } else {
                        Sheet { ProgressView().padding() }
                    }
                case .library:  LibraryView()
                case .dictate:  DictationView()
                case .settings: SettingsScreen()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColor.base)
        }
        .background(AppColor.base)
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
                    .font(AppFont.display(20, weight: .semibold))
                    .tracking(0.1)
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

            if let release = container.updates.pendingNotice {
                HairlineSoft()
                updateNotice(release)
            }

            HairlineSoft()
            HStack {
                Text(Bundle.versionBadge).uiLabel(9, color: AppColor.ink3)
                Spacer()
            }
            .padding(.horizontal, AppMetric.l)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A newer release is out. Update installs it (signed releases only),
    /// What's new opens its GitHub page, × hides this version.
    private func updateNotice(_ release: UpdateChecker.Release) -> some View {
        let phase = container.updates.installer.phase
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(AppColor.accent).frame(width: 6, height: 6)
                Text("Version \(release.version) is out").uiLabel(11)
                Spacer()
                if !phase.isWorking {
                    TapButton { container.updates.skippedVersion = release.version } label: {
                        Text("×").uiLabel(12, color: AppColor.ink3)
                    }
                    .help("Hide until the next version")
                }
            }
            switch phase {
            case .downloading, .verifying, .relaunching:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(phase == .downloading ? "Downloading…" : phase == .verifying ? "Checking signature…" : "Reopening…")
                        .font(AppFont.text(12)).foregroundStyle(AppColor.ink2)
                }
            default:
                HStack(spacing: 6) {
                    if release.installable {
                        TapButton { container.installUpdate(release) } label: {
                            LitButtonChrome(.accent, compact: true) { Text("Update") }
                        }
                    }
                    TapButton { NSWorkspace.shared.open(release.pageURL) } label: {
                        LitButtonChrome(.ghost, compact: true) { Text("What's new…") }
                    }
                }
                if case .failed(let why) = phase {
                    Text(why).font(AppFont.text(11)).foregroundStyle(AppColor.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, AppMetric.l)
        .padding(.vertical, 12)
    }

    private func sidebarRow(_ s: Section) -> some View {
        TapButton {
            section = s
        } label: {
            HStack(alignment: .center, spacing: AppMetric.s) {
                Text(String(format: "%02d", s.index))
                    .uiLabel(11, color: section == s ? AppColor.accentOnLight : AppColor.ink3)
                Text(s.label)
                    .uiLabel(11, color: section == s ? AppColor.ink : AppColor.ink2)
                Spacer()
                if section == s {
                    Rectangle().fill(AppColor.accent).frame(width: 3, height: 16)
                }
            }
            .padding(.horizontal, AppMetric.l)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(section == s ? AppColor.base : Color.clear)
            .contentShape(Rectangle())
        }

    }
}


extension Bundle {
    /// "V1·5·1 / MACOS" — always the real bundle version, so the sidebar
    /// badge can never lie about which build is running.
    static var versionBadge: String {
        let v = main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "V\(v.replacingOccurrences(of: ".", with: "·")) / macOS"
    }
}
