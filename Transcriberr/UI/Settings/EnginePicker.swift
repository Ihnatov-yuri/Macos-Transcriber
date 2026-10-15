import SwiftUI

/// An engine as the drop-downs offer it: Whisper once per model on disk
/// ("Whisper large-v3 turbo"), every other engine once. Picking a Whisper
/// entry sets the Whisper model (`whisper.model`, shared by every place
/// Whisper runs) and the engine to Whisper.
enum EngineChoice: Hashable {
    case engine(BackendFactory.Kind)
    case whisper(String)

    var kind: BackendFactory.Kind {
        switch self {
        case .engine(let k): return k
        case .whisper: return .whisper
        }
    }

    var label: String {
        switch self {
        case .engine(let k): return k.displayName
        case .whisper(let id): return "Whisper \(WhisperModel.model(id).name) (local, CoreML)"
        }
    }

    static func current(_ kind: BackendFactory.Kind, whisper: String) -> EngineChoice {
        kind == .whisper ? .whisper(WhisperModel.model(whisper).id) : .engine(kind)
    }

    /// Downloaded Whisper models, plus the one in use even before its
    /// download (it downloads on first run, as always).
    static func options(_ kinds: [BackendFactory.Kind], whisper: String) -> [EngineChoice] {
        let inUse = WhisperModel.model(whisper).id
        let models = WhisperModel.all.filter { $0.isDownloaded || $0.id == inUse }
        return kinds.flatMap { k -> [EngineChoice] in
            k == .whisper ? models.map { .whisper($0.id) } : [.engine(k)]
        }
    }
}

struct EnginePicker: View {
    let title: String
    let kinds: [BackendFactory.Kind]
    @Binding var selection: BackendFactory.Kind
    @AppStorage(WhisperModel.settingsKey) private var whisperModel = WhisperModel.defaultID

    var body: some View {
        Picker(title, selection: Binding(
            get: { EngineChoice.current(selection, whisper: whisperModel) },
            set: { choice in
                if case .whisper(let id) = choice { whisperModel = id }
                selection = choice.kind
            }
        )) {
            ForEach(EngineChoice.options(kinds, whisper: whisperModel), id: \.self) { c in
                Text(c.label).tag(c)
            }
        }
    }
}
