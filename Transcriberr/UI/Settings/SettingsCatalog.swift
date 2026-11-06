import SwiftUI

/// Every setting on the Settings screen, once: which section it lives in,
/// whether Normal shows it, and the words search looks through. The views
/// gate each setting on `SettingsFilter.shows(_:)`, and the help text they
/// print under a control is read from here where it is static, so search
/// finds exactly the words on screen.

/// Normal shows what most people change; Advanced adds the rest.
enum SettingsLevel: String, CaseIterable, Sendable {
    case normal, advanced

    static let storageKey = "settings.level"

    var title: String {
        switch self {
        case .normal: "Normal"
        case .advanced: "Advanced"
        }
    }
}

/// The foldable sections, in screen order. The raw value is the section's
/// stable key: fold state and `scrollTo` use it, whatever letter the
/// section shows.
enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case audio = "A", engines = "B", models = "C", presets = "D", style = "E", snippets = "F"
    case prompts = "G", apiKeys = "H", dictation = "I", updates = "J", assistants = "K"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .audio: "Audio input"
        case .engines: "Engines"
        case .models: "Models"
        case .presets: "Post-processing presets"
        case .style: "Style & vocabulary"
        case .snippets: "Snippets"
        case .prompts: "Prompts"
        case .apiKeys: "API keys"
        case .dictation: "Dictation"
        case .updates: "Updates"
        case .assistants: "AI assistants"
        }
    }

    /// Height of the embedded grouped `Form` when everything in it shows.
    /// Forms collapse inside a ScrollView, so they need one; nil for the
    /// sections laid out as plain stacks.
    var fullFormHeight: CGFloat? {
        switch self {
        case .engines: 430
        case .style: 900
        case .snippets: 260
        case .prompts: 480
        case .apiKeys: 480
        case .dictation: 760
        case .updates: 200
        case .audio, .models, .presets, .assistants: nil
        }
    }

    var items: [SettingID] { SettingID.allCases.filter { $0.section == self } }
}

enum SettingID: String, CaseIterable, Sendable {
    // A · Audio input
    case microphone, noiseSuppression, echoFilter, virtualMicrophone, preprocessImports, voiceprint, people
    // B · Engines
    case myName, defaultEngine, liveEngine, whisperModels, engineLanguages
    case mergeEngines, superMaxQuality, meetingSuperFollowUp, calendarContext, recordingBrief, textModelRulings
    case turnGranularity, textEngine
    // C · Models
    case textModelPicks, textModelComparison, speechModels, whisperDownloads
    // D · Presets
    case presets
    // E · Style & vocabulary
    case tone, fillersVerbatim, vocabulary, vocabularyByLanguage, learnedTerms, learnedChoices, benchmark, domainPacks
    // F · Snippets
    case snippets
    // G · Prompts
    case transcribePrompt, translatePrompt
    // H · API keys
    case apiKeys
    // I · Dictation
    case dictationHotkey, dictationAccessibility, dictationRecognition, dictationCleanup
    case dictationFormatting, dictationContext, dictationAppRules, dictationPrompt
    case dictationInsertion, dictationIndicators, dictationLinks, dictationHistory
    // J · Updates
    case updates
    // K · AI assistants
    case assistants

    var section: SettingsSection {
        switch self {
        case .microphone, .noiseSuppression, .echoFilter, .virtualMicrophone, .preprocessImports, .voiceprint, .people:
            .audio
        case .myName, .defaultEngine, .liveEngine, .whisperModels, .engineLanguages, .mergeEngines, .superMaxQuality,
             .meetingSuperFollowUp, .calendarContext, .recordingBrief, .textModelRulings, .turnGranularity, .textEngine:
            .engines
        case .textModelPicks, .textModelComparison, .speechModels, .whisperDownloads:
            .models
        case .presets:
            .presets
        case .tone, .fillersVerbatim, .vocabulary, .vocabularyByLanguage, .learnedTerms, .learnedChoices, .benchmark, .domainPacks:
            .style
        case .snippets:
            .snippets
        case .transcribePrompt, .translatePrompt:
            .prompts
        case .apiKeys:
            .apiKeys
        case .dictationHotkey, .dictationAccessibility, .dictationRecognition, .dictationCleanup, .dictationFormatting,
             .dictationContext, .dictationAppRules, .dictationPrompt, .dictationInsertion, .dictationIndicators,
             .dictationLinks, .dictationHistory:
            .dictation
        case .updates:
            .updates
        case .assistants:
            .assistants
        }
    }

    /// Normal: the input device, the default engine, the text-model picks,
    /// presets, dictation basics, updates (and the few plain choices next to
    /// them: your name, noise suppression, vocabulary). Everything else is
    /// Advanced.
    var level: SettingsLevel {
        switch self {
        case .microphone, .noiseSuppression,
             .myName, .defaultEngine, .engineLanguages,
             .textModelPicks, .textModelComparison, .speechModels,
             .presets,
             .vocabulary,
             .dictationHotkey, .dictationAccessibility, .dictationRecognition, .dictationFormatting,
             .dictationIndicators, .dictationHistory,
             .updates:
            .normal
        default:
            .advanced
        }
    }

    /// What the setting is called on screen.
    var label: String {
        switch self {
        case .microphone: "Microphone"
        case .noiseSuppression: "Noise suppression while recording"
        case .echoFilter: "Echo filter in meetings"
        case .virtualMicrophone: "Transcriberr Microphone for calls"
        case .preprocessImports: "Pre-process imported files"
        case .voiceprint: "Your voice"
        case .people: "People"
        case .myName: "My name"
        case .defaultEngine: "Default engine"
        case .liveEngine: "Live captions engine"
        case .whisperModels: "Whisper models for English, Ukrainian and other languages"
        case .engineLanguages: "Languages by engine"
        case .mergeEngines: "Super merge engines A and B"
        case .superMaxQuality: "Max quality"
        case .meetingSuperFollowUp: "Refine meetings with Super in the background"
        case .calendarContext: "Use the meeting's calendar invite"
        case .recordingBrief: "Recording brief"
        case .textModelRulings: "Text model rules on disputed chunks"
        case .turnGranularity: "Turn granularity"
        case .textEngine: "Text engine"
        case .textModelPicks: "Text models for Super merge and everything else"
        case .textModelComparison: "Text model comparison and downloads"
        case .speechModels: "Speech-to-text models"
        case .whisperDownloads: "Whisper model downloads"
        case .presets: "Post-processing presets"
        case .tone: "Tone"
        case .fillersVerbatim: "Remove fillers, Verbatim"
        case .vocabulary: "Vocabulary for all languages"
        case .vocabularyByLanguage: "Vocabulary per language"
        case .learnedTerms: "Learned from your transcripts"
        case .learnedChoices: "Your word choices"
        case .benchmark: "Your benchmark"
        case .domainPacks: "Domain packs"
        case .snippets: "Snippets"
        case .transcribePrompt: "Transcribe prompt"
        case .translatePrompt: "Translate prompt"
        case .apiKeys: "API keys"
        case .dictationHotkey: "Dictation hotkey and mode"
        case .dictationAccessibility: "Accessibility access"
        case .dictationRecognition: "Dictation engine and language"
        case .dictationCleanup: "Spoken commands, fillers and vocabulary spellings"
        case .dictationFormatting: "Apps without a rule"
        case .dictationContext: "Text around the cursor, self-corrections and live preview"
        case .dictationAppRules: "Per-app rules"
        case .dictationPrompt: "Smart pass prompt"
        case .dictationInsertion: "Spacing and clipboard"
        case .dictationIndicators: "Status strip, menu bar and sounds"
        case .dictationLinks: "transcriberr://dictate links"
        case .dictationHistory: "Keep every dictation in the Library"
        case .updates: "Check for new versions"
        case .assistants: "Let AI assistants read my library"
        }
    }

    /// The help text. Where a view prints a static paragraph under the
    /// control, it prints this string.
    var help: String {
        switch self {
        case .microphone:
            "Used for dictation, plain recordings and the meeting recorder. System default or a chosen input device; a Bluetooth mic drops to hands-free while recording; loopback devices record system audio, not a room."
        case .noiseSuppression:
            "Recommended. Applied on the input node before each chunk is written. macOS turns other apps down slightly while it runs; they come back when the recording stops."
        case .echoFilter:
            "Not needed for the transcript: Transcriberr removes the echo of the call from your mic itself. Apple's filter can silence your mic in Teams, so the other people can't hear you, and it drops short pieces of the recording. Off with headphones. Other apps play about 4 dB quieter while a meeting records."
        case .virtualMicrophone:
            "Transcriberr runs the echo filter on your mic and passes the cleaned sound to your call through a virtual microphone. In Teams, Meet or Zoom, choose it as the microphone. Needs a small audio driver."
        case .preprocessImports:
            "Runs the same cleanup over MP3 / M4A / WAV files before they are transcribed. Adds a few seconds to the decode step."
        case .voiceprint:
            "Record a short passage so meeting mode can tell your voice apart from the others. Record again or forget my voice."
        case .people:
            "Voices saved from recordings, so later recordings name these people on their own. Add person, keep learning from meetings, voice model, rename or delete."
        case .myName:
            "Meeting mode knows which voice came from your microphone — it labels that speaker with this name automatically."
        case .defaultEngine:
            "The speech-to-text engine new recordings and imports use: Parakeet, Whisper or Super, which merges two engines."
        case .liveEngine:
            "The engine that writes live captions while a recording runs."
        case .whisperModels:
            "Whisper uses the first model when a recording's languages are English only, the second for anything else, auto-detect included. On the reference set, turbo compressed made English Super about 4x faster at the same accuracy; in Ukrainian every model but large-v3 lost 5-15 points. Speech models download automatically on first use: Parakeet v3/v2/UK (~0.6-1 GB each, Neural Engine) and the Whisper models picked here (0.5-3 GB, CoreML). Whisper models can also be downloaded ahead of time, or deleted, in Models."
        case .engineLanguages:
            "Recommendations: English → Parakeet v3 (or v2). Ukrainian → Ihnatov Parakeet UK. Other European languages → Parakeet v3. Arabic → Whisper. Korean/Japanese/Chinese → Whisper. Unsure or mixed → Whisper or Super merge."
        case .mergeEngines:
            "The two engines Super runs side by side on every chunk. Picking one engine for both swaps them."
        case .superMaxQuality:
            "Arbitrate every disputed chunk with surrounding context + vocabulary."
        case .meetingSuperFollowUp:
            "When a meeting recording stops, the default engine writes a quick draft you can read at once; Super then runs in the background and replaces it when it finishes. The draft stays in VERSIONS."
        case .calendarContext:
            "Before a recording is transcribed, the invite it was made in (its title, attendees and the names in its notes) and the names that recur in your earlier meetings with the same people become vocabulary for that run. Read from the Calendar app on this Mac; nothing leaves it."
        case .recordingBrief:
            "A few extra reads (about a minute per hour of recording) give the text model the topic, the people and the names as spelled in this recording. Max-quality arbitration and the Clean / Context rewrite / Translate presets all use it, and a name spelled inconsistently is unified when the correction sounds the same."
        case .textModelRulings:
            "Both engines transcribe every chunk in parallel; disagreements are settled word by word by recognizer confidence. With Max quality on, the whole recording is also read at once (long-form Whisper, English stretches re-read in English, echo removed by timing). The text model's rulings on disputed chunks helped in English and hurt in Ukrainian when measured against checked transcripts, so by default they run for English only."
        case .turnGranularity:
            "How aggressively adjacent same-speaker segments merge into one turn. Fine matches phone-recorder granularity; applies to the next run."
        case .textEngine:
            "The on-device model is picked under Models; cloud engines need an API key. Preset prompt templates are edited under Post-processing presets; transcription prompts under Prompts."
        case .textModelPicks:
            "Super merge reads the whole meeting for names and topics, then rules on disputed words. Everything else covers summaries, cleanup, titles, person briefs, the speech coach and dictation polish."
        case .textModelComparison:
            "Gemma and Qwen side by side: speed, quality and memory, measured. Download or delete each on-device model."
        case .speechModels:
            "Parakeet v3/v2/UK are downloaded on first use (~0.6-1 GB each) and cached in Application Support."
        case .whisperDownloads:
            "Download Whisper models ahead of time, or delete them to free disk space."
        case .presets:
            "Each preset is a tab in a recording: summary, minutes, clean, translate and your own. Add, reorder, edit the prompts, restore built-in presets, history."
        case .tone:
            "The tone of cleaned-up text."
        case .fillersVerbatim:
            "Remove fillers such as um and uh, or keep the transcript verbatim."
        case .vocabulary:
            "Applied to every run. Names that work in any language (people, companies)."
        case .vocabularyByLanguage:
            "Injected only when a run's LANG matches — keeps Ukrainian runs free of English terms and vice versa."
        case .learnedTerms:
            "A capitalized word that recurs across recordings and never appears as an ordinary lowercase word is treated as a name. Learned names are applied to dictation (exact spelling, never fuzzy) and offered here; Add makes one permanent, × hides it for good."
        case .learnedChoices:
            "The disputed words you settled by hand in Super transcripts. Super then picks that reading whenever the engines split the same way."
        case .benchmark:
            "Keep corrected lines as a benchmark: a line you correct keeps a copy of its audio, so any engine can be scored on it."
        case .domainPacks:
            "Add a ready-made list of terms for a field to your vocabulary."
        case .snippets:
            "Reusable text blocks for prompts: write {snippet:name} inside any preset or prompt template."
        case .transcribePrompt:
            "The prompt sent with audio to transcribe with a cloud engine."
        case .translatePrompt:
            "The prompt used to translate a transcript."
        case .apiKeys:
            "Keys for cloud engines, stored in the Keychain."
        case .dictationHotkey:
            "A right-hand modifier is never a shortcut on its own, so it can't collide with the app you're typing in. If you pick fn / Globe, set “Press 🌐 key to” → Do Nothing in System Settings → Keyboard so macOS dictation doesn't also start. Accessibility access is what lets Transcriberr see the key in other apps and paste the result."
        case .dictationAccessibility:
            "Lets Transcriberr see the hotkey in other apps and paste the result."
        case .dictationRecognition:
            "The engine and language dictation listens with."
        case .dictationCleanup:
            "Parakeet decodes a whole passage in well under a second on the Neural Engine, punctuation and casing included. Vocabulary terms are matched exactly (case- and spacing-insensitive) and rewritten to their canonical spelling — never fuzzily."
        case .dictationFormatting:
            "Verbatim inserts the recognizer's words untouched. Clean applies the deterministic passes (vocabulary, fillers, commands, self-corrections) in well under a second. Smart additionally runs the text model with the target app, its register, and the text before the cursor — chat stays short and casual, mail gets full sentences, an enumeration becomes a list. Smart uses the text engine chosen under Post-processing; if that is a cloud engine, the dictated passage is sent to it, but the window title and the text around your cursor never leave this Mac. Password fields are always verbatim and never read."
        case .dictationContext:
            "Read the text around the cursor, apply spoken self-corrections, follow the language of the field, live preview while speaking, use names learned from my transcripts."
        case .dictationAppRules:
            "Rules match the app's bundle identifier; an identifier ending in “.” matches a family (com.jetbrains.). Terminals and code editors default to verbatim, chat apps to smart & casual, mail to smart & formal."
        case .dictationPrompt:
            "Appended to the built-in context prompt when you change it. Uses the post-processing text engine (Settings → Engines); a second or two per passage on the on-device model. A result that isn't clearly the same passage (wrong length, answers the text, echoes the prompt) is discarded in favour of the deterministic output."
        case .dictationInsertion:
            "Text is inserted with ⌘V into whatever has keyboard focus; the previous clipboard contents come back 0.8 s later. Automatic spacing reads the characters before the cursor through Accessibility (a space only after a word, a capital only at a sentence start) and falls back to a trailing space where an app hides its text. Say “scratch that” to take the last passage back. When Transcriberr itself is in front with the Dictate screen open, text goes to its scratch pad instead."
        case .dictationIndicators:
            "Show the floating status strip, show in the menu bar, start / stop sounds."
        case .dictationLinks:
            "Allow transcriberr://dictate links (text goes to the Dictate screen)."
        case .dictationHistory:
            "Each passage is saved with its audio as a normal recording: playable, re-transcribable with another engine, searchable through the knowledge-base CLI and MCP server."
        case .updates:
            "Check for new versions once a day, check now and update. The check reads the public latest-release record on GitHub and sends nothing about this Mac."
        case .assistants:
            "Claude and other assistants connected to Transcriberr through the MCP server can list, search and read your transcripts, outputs, folders and tags. They can never change or delete anything."
        }
    }

    /// Words a person might search for that the label and help leave out.
    var keywords: String {
        switch self {
        case .microphone: "input device mic audio bluetooth loopback"
        case .noiseSuppression: "voice processing noise denoise agc"
        case .echoFilter: "aec echo cancellation teams zoom headphones"
        case .virtualMicrophone: "virtual mic driver call teams meet zoom"
        case .voiceprint: "voice print speaker me enrol"
        case .people: "speakers voices names voice model"
        case .myName: "you me name speaker"
        case .defaultEngine: "asr speech recognition parakeet whisper super transcription"
        case .liveEngine: "live captions realtime"
        case .whisperModels: "turbo large-v3 distil"
        case .engineLanguages: "language ukrainian english arabic dutch"
        case .mergeEngines, .superMaxQuality, .textModelRulings: "super dual-engine ensemble"
        case .calendarContext: "calendar invite attendees meeting"
        case .recordingBrief: "brief summary names topic"
        case .turnGranularity: "speakers diarization turns"
        case .textEngine: "cloud llm summaries cleanup translation titles"
        case .textModelPicks, .textModelComparison: "gemma qwen llm text model download ram memory"
        case .speechModels: "parakeet download"
        case .whisperDownloads: "whisper download delete disk"
        case .presets: "summary minutes templates output"
        case .tone: "style neutral formal casual enthusiastic technical"
        case .fillersVerbatim: "style"
        case .vocabulary, .vocabularyByLanguage: "names spelling terms words glossary"
        case .learnedTerms: "names vocabulary suggestions"
        case .benchmark: "wer reference corrected"
        case .domainPacks: "vocabulary terms medical it software construction legal finance"
        case .snippets: "placeholder template"
        case .transcribePrompt, .translatePrompt: "template system prompt"
        case .apiKeys: "openai anthropic google gemini claude key keychain cloud token"
        case .dictationHotkey: "shortcut key fn globe push to talk toggle pause"
        case .dictationAccessibility: "permission privacy"
        case .dictationRecognition: "language engine auto-detect"
        case .dictationFormatting: "verbatim clean smart format"
        case .dictationContext: "cursor context language"
        case .dictationAppRules: "bundle identifier app"
        case .dictationPrompt: "polish smart prompt"
        case .dictationInsertion: "paste clipboard spacing"
        case .dictationIndicators: "hud menu bar sound"
        case .dictationHistory: "library history save"
        case .updates: "update version release github"
        case .assistants: "mcp claude cli kb knowledge base privacy"
        default: ""
        }
    }

    /// Rough height of this setting's rows inside its grouped Form, used
    /// to size the Form when only some of its settings show.
    var formRowsHeight: CGFloat {
        switch self {
        case .myName: 90
        case .defaultEngine: 40
        case .liveEngine: 40
        case .whisperModels: 220
        case .engineLanguages: 230
        case .mergeEngines: 80
        case .superMaxQuality: 40
        case .meetingSuperFollowUp: 90
        case .calendarContext: 110
        case .recordingBrief: 100
        case .textModelRulings: 130
        case .turnGranularity: 90
        case .textEngine: 80
        case .tone: 40
        case .fillersVerbatim: 70
        case .vocabulary: 160
        case .vocabularyByLanguage: 180
        case .learnedTerms: 260
        case .learnedChoices: 130
        case .benchmark: 180
        case .domainPacks: 200
        case .snippets: 260
        case .transcribePrompt, .translatePrompt: 170
        case .apiKeys: 480
        case .dictationHotkey: 180
        case .dictationAccessibility: 60
        case .dictationRecognition: 80
        case .dictationCleanup: 160
        case .dictationFormatting: 170
        case .dictationContext: 170
        case .dictationAppRules: 280
        case .dictationPrompt: 230
        case .dictationInsertion: 160
        case .dictationIndicators: 100
        case .dictationLinks: 40
        case .dictationHistory: 90
        case .updates: 200
        default: 0
        }
    }

    /// Folded label, help, keywords and section title: what a query is
    /// matched against.
    var searchText: String {
        SettingsFilter.fold([label, help, keywords, section.title].joined(separator: " "))
    }
}

/// What the Settings screen shows right now: a level, and a query that,
/// when present, overrides the level (search always covers everything).
/// The default shows everything, so the tabs keep working unfiltered in
/// the macOS Settings scene.
struct SettingsFilter: Equatable, Sendable {
    var level: SettingsLevel = .advanced
    var query: String = ""

    static let everything = SettingsFilter()

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The query's words, folded. Every word has to appear.
    var terms: [String] {
        let words = Self.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        // "turn off noise suppression" looks for the setting, not the verb.
        let kept = words.filter { !Self.requestWords.contains($0) }
        return kept.isEmpty ? words : kept
    }

    private static let requestWords: Set<String> = ["turn", "off", "on", "switch", "enable", "disable", "change",
                                                    "set", "the", "a", "an", "to", "my", "please", "make", "use"]

    var isSearching: Bool { !terms.isEmpty }

    /// Something is hidden that Advanced with no query would show.
    var isNarrowed: Bool { isSearching || level == .normal }

    func matches(_ id: SettingID) -> Bool {
        let haystack = id.searchText
        return terms.allSatisfy { haystack.contains($0) }
    }

    func shows(_ id: SettingID) -> Bool {
        if isSearching { return matches(id) }
        return level == .advanced || id.level == .normal
    }

    func showsAny(_ ids: SettingID...) -> Bool { ids.contains(where: shows) }

    func visible(in section: SettingsSection) -> [SettingID] { section.items.filter(shows) }

    func showsSection(_ section: SettingsSection) -> Bool { !visible(in: section).isEmpty }

    var visibleSections: [SettingsSection] { SettingsSection.allCases.filter(showsSection) }

    /// Matches that Normal on its own would hide: search shows them, and
    /// the screen says they are Advanced.
    func advancedMatches(in section: SettingsSection) -> [SettingID] {
        guard isSearching, level == .normal else { return [] }
        return visible(in: section).filter { $0.level == .advanced }
    }

    /// The height for a section's embedded Form: the full height when
    /// nothing is hidden, otherwise an estimate from the settings that show.
    func formHeight(for section: SettingsSection) -> CGFloat {
        guard let full = section.fullFormHeight else { return 0 }
        guard isNarrowed else { return full }
        let estimate = visible(in: section).map(\.formRowsHeight).reduce(40, +)
        return min(full, max(estimate, 80))
    }
}

extension EnvironmentValues {
    @Entry var settingsFilter: SettingsFilter = .everything
}
