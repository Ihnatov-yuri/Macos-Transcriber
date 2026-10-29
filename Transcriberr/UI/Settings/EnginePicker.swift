import SwiftUI

/// An engine drop-down. Whisper is one entry: its model follows the run's
/// language (Settings → Engines, "Whisper for English", "Whisper for
/// Ukrainian" and "Whisper for other languages"), so a model per entry would only be right for some
/// recordings.
struct EnginePicker: View {
    let title: String
    let kinds: [BackendFactory.Kind]
    @Binding var selection: BackendFactory.Kind

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(kinds, id: \.self) { Text($0.displayName).tag($0) }
        }
    }
}

/// The three Whisper model pickers: English runs, Ukrainian runs and every
/// other run. Each offers the models for its language: English-only ones
/// only for English, Whisper UK only for Ukrainian.
struct WhisperModelPickers: View {
    @AppStorage(WhisperModel.englishSettingsKey) private var english = WhisperModel.englishDefaultID
    @AppStorage(WhisperModel.ukrainianSettingsKey) private var ukrainian = WhisperModel.ukrainianDefaultID
    @AppStorage(WhisperModel.settingsKey) private var other = WhisperModel.defaultID

    var body: some View {
        Picker("Whisper for English", selection: $english) {
            ForEach(WhisperModel.all.filter { !$0.ukrainianOnly }) { Text(label($0)).tag($0.id) }
        }
        Picker("Whisper for Ukrainian", selection: $ukrainian) {
            ForEach(WhisperModel.all.filter { !$0.englishOnly }) { Text(label($0)).tag($0.id) }
        }
        Picker("Whisper for other languages", selection: $other) {
            ForEach(WhisperModel.all.filter { !$0.englishOnly && !$0.ukrainianOnly }) { Text(label($0)).tag($0.id) }
        }
    }

    private func label(_ m: WhisperModel) -> String {
        "\(m.name)\(m.englishOnly ? " (English only)" : "")\(m.isDownloaded ? "" : " · not downloaded")"
    }
}
