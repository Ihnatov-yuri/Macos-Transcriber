import SwiftUI

/// Where an "ask to change a setting" request stands.
enum SettingsAskPhase: Equatable {
    case idle
    case thinking(request: String)
    case proposal(request: String, SettingsAskResult)
    case failed(request: String, message: String)
    case applied([SettingChange], SettingsAsk.Snapshot)
    case undone([SettingChange])
}

/// Under the search field: the model at work, the proposed changes with
/// Apply and Cancel, then Undo. Lit Field Operate mode: a veiled panel,
/// one primary action, alerts with a 3pt rule in the status colour.
struct SettingsAskPanel: View {
    let phase: SettingsAskPhase
    var onApply: ([SettingChange]) -> Void
    var onUndo: (SettingsAsk.Snapshot) -> Void
    var onDismiss: () -> Void

    var body: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .thinking(let request):
            panel {
                HStack(spacing: AppMetric.s) {
                    ProgressView().controlSize(.small)
                    Text("Reading \u{201C}\(request)\u{201D} with the on-device text model. Nothing changes until you apply it.")
                        .font(AppFont.text(13))
                        .foregroundStyle(AppColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    TapButton(action: onDismiss) {
                        LitButtonChrome(.ghost, compact: true) { Text("Cancel") }
                    }
                }
            }
        case .proposal(let request, let result):
            proposal(request, result)
        case .failed(_, let message):
            alert(color: AppColor.statusError) {
                VStack(alignment: .leading, spacing: AppMetric.s) {
                    Text(message)
                        .font(AppFont.text(13))
                        .foregroundStyle(AppColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    TapButton(action: onDismiss) {
                        LitButtonChrome(.secondary, compact: true) { Text("Dismiss") }
                    }
                }
            }
        case .applied(let changes, let snapshot):
            panel {
                VStack(alignment: .leading, spacing: AppMetric.s) {
                    Text(changes.count == 1 ? "Changed" : "Changed \(changes.count) settings")
                        .uiLabel(9, color: AppColor.statusSuccess)
                    changeRows(changes)
                    HStack(spacing: AppMetric.s) {
                        TapButton { onUndo(snapshot) } label: {
                            LitButtonChrome(.secondary, compact: true) { Text("Undo") }
                        }
                        TapButton(action: onDismiss) {
                            LitButtonChrome(.ghost, compact: true) { Text("Done") }
                        }
                    }
                }
            }
        case .undone(let changes):
            panel {
                HStack(spacing: AppMetric.s) {
                    Text(changes.count == 1
                         ? "Put back: \(changes[0].label) is \(changes[0].fromName) again."
                         : "Put back the \(changes.count) settings as they were.")
                        .font(AppFont.text(13))
                        .foregroundStyle(AppColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    TapButton(action: onDismiss) {
                        LitButtonChrome(.ghost, compact: true) { Text("Done") }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func proposal(_ request: String, _ result: SettingsAskResult) -> some View {
        let notes = result.unchanged + result.dropped
        if result.changes.isEmpty {
            alert(color: AppColor.statusWarning) {
                VStack(alignment: .leading, spacing: AppMetric.s) {
                    Text("Nothing to change for \u{201C}\(request)\u{201D}.")
                        .font(AppFont.text(13, weight: .semibold))
                        .foregroundStyle(AppColor.ink)
                    noteList(notes.isEmpty
                             ? ["The request didn't match a setting a request can change. Search for the setting instead, or name it, such as \u{201C}turn off the echo filter\u{201D}."]
                             : notes)
                    TapButton(action: onDismiss) {
                        LitButtonChrome(.secondary, compact: true) { Text("Dismiss") }
                    }
                }
            }
        } else {
            panel {
                VStack(alignment: .leading, spacing: AppMetric.s) {
                    Text(result.changes.count == 1 ? "Change this setting?" : "Change these \(result.changes.count) settings?")
                        .uiLabel(9, color: AppColor.ink2)
                    changeRows(result.changes)
                    if !notes.isEmpty {
                        noteList(notes)
                    }
                    HStack(spacing: AppMetric.s) {
                        TapButton { onApply(result.changes) } label: {
                            LitButtonChrome(.primary, compact: true) { Text("Apply") }
                        }
                        TapButton(action: onDismiss) {
                            LitButtonChrome(.secondary, compact: true) { Text("Cancel") }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private func changeRows(_ changes: [SettingChange]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(changes.enumerated()), id: \.element.id) { index, change in
                if index > 0 { HairlineSoft() }
                HStack(alignment: .firstTextBaseline, spacing: AppMetric.s) {
                    Text(change.label)
                        .font(AppFont.text(13, weight: .semibold))
                        .foregroundStyle(AppColor.ink)
                        .frame(minWidth: 180, alignment: .leading)
                    Text(change.fromName)
                        .font(AppFont.text(13))
                        .foregroundStyle(AppColor.ink3)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppColor.accentOnLight)
                        .accessibilityHidden(true)
                    Text(change.toName)
                        .font(AppFont.text(13, weight: .semibold))
                        .foregroundStyle(AppColor.ink)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(change.label): \(change.fromName) to \(change.toName)")
            }
        }
    }

    private func noteList(_ notes: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(notes, id: \.self) { note in
                Text(note)
                    .font(AppFont.text(12))
                    .foregroundStyle(AppColor.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func panel(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(AppMetric.m)
            .frame(maxWidth: 640, alignment: .leading)
            .litGlass(strong: true)
            .litLift(.one)
    }

    /// Lit Field alert: a panel with a 3pt left rule in the status colour.
    private func alert(color: Color, @ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(AppMetric.m)
            .padding(.leading, 3)
            .frame(maxWidth: 640, alignment: .leading)
            .litGlass(strong: true)
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(topLeadingRadius: AppMetric.radiusSm, bottomLeadingRadius: AppMetric.radiusSm,
                                       style: .continuous)
                    .fill(color)
                    .frame(width: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: AppMetric.radiusSm, style: .continuous))
            .litLift(.one)
    }
}
