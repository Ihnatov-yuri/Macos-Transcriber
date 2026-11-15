import EventKit
import Foundation

/// "Ask to change a setting": a request in plain words ("turn off the echo
/// filter") goes to the on-device text model with a compact list of the
/// settings it may touch, the model answers with JSON, and the answer is
/// checked against that list before anything is shown. Nothing changes
/// until the person presses Apply.
///
/// Only plain values are offered: toggles, pickers, one number and one
/// short text. API keys, the virtual microphone's driver, voice
/// recordings, people, presets, prompts, vocabulary, app rules and every
/// one-shot action (downloads, deletes, domain packs) stay out.

// MARK: - The stores a setting lives in

/// Everything an accessor reads or writes. The app passes its container's
/// stores; `defaults` is where the `@AppStorage` keys live.
struct SettingsStores {
    let ui: UIPrefs
    let recorder: RecorderSettings
    let dictation: DictationSettings
    let prompts: PromptStore
    let updates: UpdateChecker
    let defaults: UserDefaults

    init(ui: UIPrefs, recorder: RecorderSettings = .shared, dictation: DictationSettings,
         prompts: PromptStore, updates: UpdateChecker, defaults: UserDefaults = .standard) {
        self.ui = ui
        self.recorder = recorder
        self.dictation = dictation
        self.prompts = prompts
        self.updates = updates
        self.defaults = defaults
    }

    init(container: AppContainer) {
        self.init(ui: container.uiPrefs, dictation: container.dictationSettings,
                  prompts: container.promptStore, updates: container.updates)
    }
}

// MARK: - Value kinds

struct SettingOption: Hashable, Sendable {
    let value: String
    let name: String
}

enum SettingKind: Equatable {
    case toggle
    case choice([SettingOption])
    case number(ClosedRange<Double>, step: Double, unit: String)
    case text(maxLength: Int)

    /// The value as the person reads it: "On", an option's name, "1.5 s".
    func displayName(_ value: String) -> String {
        switch self {
        case .toggle: return value == "on" ? String(localized: "On", comment: "A setting's value: switched on") : String(localized: "Off", comment: "A setting's value: switched off")
        case .choice(let options): return options.first { $0.value == value }?.name ?? value
        case .number(_, _, let unit): return unit.isEmpty ? value : "\(value) \(unit)"
        case .text: return value.isEmpty ? String(localized: "(empty)", comment: "A text setting with nothing in it") : "\u{201C}\(value)\u{201D}"
        }
    }

    /// What the model is told it may answer.
    var allowedSummary: String {
        switch self {
        case .toggle: return "on | off"
        case .choice(let options):
            return options.map { $0.value == $0.name ? $0.value : "\($0.value) (\($0.name))" }.joined(separator: " | ")
        case .number(let range, let step, let unit):
            return "number \(SettingKind.format(range.lowerBound, step: step))–\(SettingKind.format(range.upperBound, step: step))\(unit.isEmpty ? "" : " \(unit)"), step \(SettingKind.format(step, step: step))"
        case .text(let max): return "text, up to \(max) characters"
        }
    }

    /// What the person is told the setting takes, in their language; the
    /// model gets `allowedSummary`.
    var allowedForPeople: String {
        switch self {
        case .toggle:
            return String(localized: "\(displayName("on")) or \(displayName("off"))", comment: "The values a switch takes: On or Off")
        case .choice(let options):
            return options.map(\.name).formatted(.list(type: .or))
        case .number(let range, let step, let unit):
            let low = SettingKind.format(range.lowerBound, step: step)
            let high = SettingKind.format(range.upperBound, step: step)
            return unit.isEmpty
                ? String(localized: "a number from \(low) to \(high)")
                : String(localized: "a number from \(low) to \(high) \(unit)")
        case .text(let max):
            return String(localized: "text of up to \(max) characters")
        }
    }

    /// A JSON true/false (or a Swift Bool), not a number that happens to
    /// be 0 or 1: both bridge to NSNumber.
    static func isBool(_ raw: Any) -> Bool {
        guard let n = raw as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    static func format(_ x: Double, step: Double) -> String {
        let decimals = step >= 1 ? 0 : step >= 0.1 ? 1 : 2
        return String(format: "%.\(decimals)f", x)
    }

    /// The canonical value for whatever the model wrote, or nil when it is
    /// not one this setting takes. Toggles take booleans and the usual
    /// words; choices their value or their name; numbers a number in range
    /// (snapped to the step); text a string up to the limit.
    func normalize(_ raw: Any) -> String? {
        switch self {
        case .toggle:
            if let n = raw as? NSNumber {
                if SettingKind.isBool(raw) { return n.boolValue ? "on" : "off" }
                return n.doubleValue == 1 ? "on" : n.doubleValue == 0 ? "off" : nil
            }
            guard let s = raw as? String else { return nil }
            switch SettingsFilter.fold(s.trimmingCharacters(in: .whitespaces)) {
            case "on", "true", "yes", "enabled", "enable", "1": return "on"
            case "off", "false", "no", "disabled", "disable", "0": return "off"
            default: return nil
            }
        case .choice(let options):
            let s: String
            if let str = raw as? String { s = str } else if let n = raw as? NSNumber, !SettingKind.isBool(raw) { s = n.stringValue } else { return nil }
            let folded = SettingsFilter.fold(s.trimmingCharacters(in: .whitespaces))
            if let hit = options.first(where: { SettingsFilter.fold($0.value) == folded }) { return hit.value }
            if let hit = options.first(where: { SettingsFilter.fold($0.name) == folded }) { return hit.value }
            // The catalog's "value (name)" copied back whole (the 26B does
            // this): without this match the right choice is turned down.
            if let hit = options.first(where: { folded.hasPrefix(SettingsFilter.fold($0.value) + " (") }) { return hit.value }
            // Numbers written another way ("10.0" for "10").
            if let x = Double(folded), let hit = options.first(where: { Double($0.value) == x }) { return hit.value }
            return nil
        case .number(let range, let step, _):
            let x: Double
            if SettingKind.isBool(raw) { return nil }
            if let n = raw as? NSNumber { x = n.doubleValue }
            else if let s = raw as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)) { x = d }
            else { return nil }
            guard x.isFinite, range.contains(x) else { return nil }
            let snapped = (x / step).rounded() * step
            return SettingKind.format(min(max(snapped, range.lowerBound), range.upperBound), step: step)
        case .text(let max):
            guard let s = raw as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count <= max, !t.contains(where: \.isNewline) else { return nil }
            return t
        }
    }
}

/// The tone's name on screen. The raw value is what is stored.
extension PromptStore.Tone {
    var settingsTitle: String {
        switch self {
        case .neutral: String(localized: "Neutral", comment: "Tone of cleaned-up text")
        case .formal: String(localized: "Formal", comment: "Tone of cleaned-up text")
        case .casual: String(localized: "Casual", comment: "Tone of cleaned-up text")
        case .enthusiastic: String(localized: "Enthusiastic", comment: "Tone of cleaned-up text")
        case .technical: String(localized: "Technical", comment: "Tone of cleaned-up text")
        }
    }
}

// MARK: - Accessors

/// One value a request may change. `key` is what the model answers with:
/// the setting's id, or id.part where one setting holds several controls
/// ("mergeEngines.a", "dictationContext.livePreview").
struct SettingAccessor: Identifiable {
    let key: String
    let setting: SettingID
    let label: String
    let kind: (SettingsStores) -> SettingKind
    let get: (SettingsStores) -> String
    let set: (SettingsStores, String) -> Void
    /// Keys this one can change as a side effect (merge engines swap).
    var coupled: [String] = []

    var id: String { key }
}

enum SettingAccessors {
    /// Settings a request never changes, with the reason the person is told.
    static func exclusion(_ id: SettingID) -> String? {
        switch id {
        case .apiKeys: String(localized: "API keys are only typed by hand.")
        case .virtualMicrophone: String(localized: "the Transcriberr Microphone needs its audio driver installed by hand.")
        case .voiceprint: String(localized: "your voice is a recording, not a value.")
        case .people: String(localized: "people and their voices are recordings, not values.")
        case .presets: String(localized: "presets are edited by hand.")
        case .snippets: String(localized: "snippets are edited by hand.")
        case .transcribePrompt, .translatePrompt, .dictationPrompt: String(localized: "prompts are edited by hand.")
        case .vocabulary, .vocabularyByLanguage: String(localized: "vocabulary is edited by hand, so nothing in it is lost.")
        case .learnedTerms, .learnedChoices: String(localized: "learned terms and choices are kept or hidden one by one.")
        case .domainPacks: String(localized: "a domain pack is added by hand.")
        case .dictationAppRules: String(localized: "per-app rules are edited by hand.")
        case .dictationAccessibility: String(localized: "Accessibility access is granted in System Settings.")
        case .textModelComparison, .speechModels, .whisperDownloads: String(localized: "models are downloaded or deleted by hand.")
        case .engineLanguages: String(localized: "it is a table of which engine knows which language.")
        // Privacy switches: what leaves this Mac and who may read the
        // library change only by the person's own hand, like API keys.
        case .textEngine: String(localized: "choosing a cloud engine sends transcripts off this Mac, so it is picked by hand.")
        case .assistants: String(localized: "access to your library is granted by hand.")
        case .dictationLinks, .dictationHistory, .dictationIndicators, .dictationInsertion,
             .microphone, .noiseSuppression, .echoFilter, .preprocessImports, .myName, .defaultEngine,
             .liveEngine, .liveSpeechCheck, .followMeetingMute, .whisperModels, .mergeEngines, .superMaxQuality, .meetingSuperFollowUp,
             .calendarContext, .recordingBrief, .textModelRulings, .turnGranularity,
             .textModelPicks, .tone, .fillersVerbatim, .benchmark, .dictationHotkey, .dictationRecognition,
             .dictationCleanup, .dictationFormatting, .dictationContext, .updates:
            nil
        }
    }

    static func accessor(_ key: String) -> SettingAccessor? { byKey[key] }

    private static let byKey: [String: SettingAccessor] =
        Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })

    // Small builders, so the table below reads one line per control.
    private static func toggle(_ key: String, _ setting: SettingID, _ label: String,
                               get: @escaping (SettingsStores) -> Bool,
                               set: @escaping (SettingsStores, Bool) -> Void) -> SettingAccessor {
        SettingAccessor(key: key, setting: setting, label: label, kind: { _ in .toggle },
                        get: { get($0) ? "on" : "off" }, set: { set($0, $1 == "on") })
    }

    private static func defaultsToggle(_ key: String, _ setting: SettingID, _ label: String,
                                       defaultsKey: String, default def: Bool) -> SettingAccessor {
        toggle(key, setting, label,
               get: { ($0.defaults.object(forKey: defaultsKey) as? Bool) ?? def },
               set: { $0.defaults.set($1, forKey: defaultsKey) })
    }

    private static func kinds(_ kinds: [BackendFactory.Kind]) -> [SettingOption] {
        kinds.map { SettingOption(value: $0.rawValue, name: $0.displayName) }
    }

    private static func choice<E: RawRepresentable & CaseIterable>(
        _ key: String, _ setting: SettingID, _ label: String, _: E.Type, name: @escaping (E) -> String,
        get: @escaping (SettingsStores) -> E, set: @escaping (SettingsStores, E) -> Void
    ) -> SettingAccessor where E.RawValue == String {
        SettingAccessor(key: key, setting: setting, label: label,
                        kind: { _ in .choice(E.allCases.map { SettingOption(value: $0.rawValue, name: name($0)) }) },
                        get: { get($0).rawValue },
                        set: { s, v in if let e = E(rawValue: v) { set(s, e) } })
    }

    private static func engine(_ key: String, _ setting: SettingID, _ label: String,
                               options: @escaping () -> [BackendFactory.Kind],
                               get: @escaping (SettingsStores) -> BackendFactory.Kind,
                               set: @escaping (SettingsStores, BackendFactory.Kind) -> Void,
                               coupled: [String] = []) -> SettingAccessor {
        SettingAccessor(key: key, setting: setting, label: label,
                        kind: { _ in .choice(kinds(options())) },
                        get: { get($0).rawValue },
                        set: { s, v in if let k = BackendFactory.Kind(rawValue: v), options().contains(k) { set(s, k) } },
                        coupled: coupled)
    }

    private static func whisper(_ key: String, _ label: String, defaultsKey: String, defaultID: String,
                                offers: @escaping (WhisperModel) -> Bool) -> SettingAccessor {
        let models = { WhisperModel.all.filter(offers) }
        return SettingAccessor(
            key: key, setting: .whisperModels, label: label,
            kind: { _ in .choice(models().map { SettingOption(value: $0.id, name: $0.name) }) },
            get: { $0.defaults.string(forKey: defaultsKey) ?? defaultID },
            set: { s, v in if models().contains(where: { $0.id == v }) { s.defaults.set(v, forKey: defaultsKey) } })
    }

    private static func textModel(_ key: String, _ label: String,
                                  get: @escaping (SettingsStores) -> String,
                                  set: @escaping (SettingsStores, String) -> Void) -> SettingAccessor {
        SettingAccessor(
            key: key, setting: .textModelPicks, label: label,
            kind: { _ in .choice(ModelCatalog.entries.map { SettingOption(value: $0.id, name: $0.name) }) },
            get: get,
            set: { s, v in if ModelCatalog.entry(id: v) != nil { set(s, v) } })
    }

    // Only on-device engines: a cloud engine sends recordings off this Mac,
    // so like the text engine it is picked by hand, never by a request.
    private static let audioEngines = { BackendFactory.Kind.allCases.filter { $0.isLocal && $0.supportsAudio } }
    private static let liveEngines = { BackendFactory.Kind.allCases.filter { $0.isLocal && $0.supportsLive } }
    private static let mergeEngines = {
        BackendFactory.Kind.allCases.filter { $0.isLocal && $0.supportsAudio && $0 != .ensemble }
    }

    /// Every value a request may change, in screen order.
    static let all: [SettingAccessor] = [
        // A · Audio input
        SettingAccessor(
            key: SettingID.microphone.rawValue, setting: .microphone, label: SettingID.microphone.label,
            kind: { s in
                let system = SettingOption(value: "system", name: String(localized: "System default"))
                var options = [system] + AudioInputDevices.microphones().map { SettingOption(value: $0.uid, name: $0.name) }
                // A chosen mic that is unplugged stays a value it holds.
                if let uid = s.recorder.inputDeviceUID, !options.contains(where: { $0.value == uid }) {
                    options.append(SettingOption(value: uid, name: String(localized: "\(uid) (not connected)", comment: "A chosen microphone that is unplugged; the value is its device id")))
                }
                return .choice(options)
            },
            get: { $0.recorder.inputDeviceUID ?? "system" },
            set: { s, v in s.recorder.inputDeviceUID = v == "system" ? nil : v }),
        toggle(SettingID.noiseSuppression.rawValue, .noiseSuppression, SettingID.noiseSuppression.label,
               get: { $0.recorder.noiseSuppression }, set: { $0.recorder.noiseSuppression = $1 }),
        toggle(SettingID.echoFilter.rawValue, .echoFilter, SettingID.echoFilter.label,
               get: { $0.recorder.meetingEchoFilter }, set: { $0.recorder.meetingEchoFilter = $1 }),
        toggle(SettingID.preprocessImports.rawValue, .preprocessImports, SettingID.preprocessImports.label,
               get: { $0.recorder.preprocessImports }, set: { $0.recorder.preprocessImports = $1 }),

        // B · Engines
        SettingAccessor(
            key: SettingID.myName.rawValue, setting: .myName, label: SettingID.myName.label,
            kind: { _ in .text(maxLength: 60) },
            get: { $0.defaults.string(forKey: "ui.myName") ?? "" },
            set: { $0.defaults.set($1, forKey: "ui.myName") }),
        engine(SettingID.defaultEngine.rawValue, .defaultEngine, SettingID.defaultEngine.label, options: audioEngines,
               get: { $0.ui.defaultBackend }, set: { $0.ui.defaultBackend = $1 }),
        engine(SettingID.liveEngine.rawValue, .liveEngine, SettingID.liveEngine.label, options: liveEngines,
               get: { $0.ui.liveEngine }, set: { $0.ui.liveEngine = $1 }),
        whisper("whisperModels.english", String(localized: "Whisper for English"),
                defaultsKey: WhisperModel.englishSettingsKey, defaultID: WhisperModel.englishDefaultID,
                offers: { !$0.ukrainianOnly }),
        whisper("whisperModels.ukrainian", String(localized: "Whisper for Ukrainian"),
                defaultsKey: WhisperModel.ukrainianSettingsKey, defaultID: WhisperModel.ukrainianDefaultID,
                offers: { !$0.englishOnly }),
        whisper("whisperModels.other", String(localized: "Whisper for other languages"),
                defaultsKey: WhisperModel.settingsKey, defaultID: WhisperModel.defaultID,
                offers: { !$0.englishOnly && !$0.ukrainianOnly }),
        // Picking the other engine's choice swaps them, as on screen.
        engine("mergeEngines.a", .mergeEngines, String(localized: "Super merge engine A"), options: mergeEngines,
               get: { $0.ui.ensembleEngineA },
               set: { s, k in
                   if k == s.ui.ensembleEngineB { s.ui.ensembleEngineB = s.ui.ensembleEngineA }
                   s.ui.ensembleEngineA = k
               }, coupled: ["mergeEngines.b"]),
        engine("mergeEngines.b", .mergeEngines, String(localized: "Super merge engine B"), options: mergeEngines,
               get: { $0.ui.ensembleEngineB },
               set: { s, k in
                   if k == s.ui.ensembleEngineA { s.ui.ensembleEngineA = s.ui.ensembleEngineB }
                   s.ui.ensembleEngineB = k
               }, coupled: ["mergeEngines.a"]),
        toggle(SettingID.liveSpeechCheck.rawValue, .liveSpeechCheck, SettingID.liveSpeechCheck.label,
               get: { $0.ui.liveSpeechCheck }, set: { $0.ui.liveSpeechCheck = $1 }),
        toggle(SettingID.followMeetingMute.rawValue, .followMeetingMute, SettingID.followMeetingMute.label,
               get: { $0.ui.followMeetingMute }, set: { $0.ui.followMeetingMute = $1 }),
        toggle(SettingID.superMaxQuality.rawValue, .superMaxQuality, String(localized: "Super max quality"),
               get: { $0.ui.superMaxQuality }, set: { $0.ui.superMaxQuality = $1 }),
        toggle(SettingID.meetingSuperFollowUp.rawValue, .meetingSuperFollowUp, SettingID.meetingSuperFollowUp.label,
               get: { $0.ui.meetingSuperFollowUp }, set: { $0.ui.meetingSuperFollowUp = $1 }),
        defaultsToggle(SettingID.calendarContext.rawValue, .calendarContext, SettingID.calendarContext.label,
                       defaultsKey: MeetingContext.enabledKey, default: true),
        defaultsToggle(SettingID.recordingBrief.rawValue, .recordingBrief, SettingID.recordingBrief.label,
                       defaultsKey: "ui.meetingBrief", default: true),
        SettingAccessor(
            key: SettingID.textModelRulings.rawValue, setting: .textModelRulings, label: SettingID.textModelRulings.label,
            kind: { _ in .choice([SettingOption(value: "english", name: String(localized: "English runs")),
                                  SettingOption(value: "all", name: String(localized: "All languages")),
                                  SettingOption(value: "off", name: String(localized: "Never"))]) },
            get: { $0.defaults.string(forKey: "ui.superGemmaRulings") ?? "english" },
            set: { s, v in if ["english", "all", "off"].contains(v) { s.defaults.set(v, forKey: "ui.superGemmaRulings") } }),
        SettingAccessor(
            key: SettingID.turnGranularity.rawValue, setting: .turnGranularity, label: SettingID.turnGranularity.label,
            kind: { _ in .choice([SettingOption(value: "30", name: String(localized: "Smooth")),
                                  SettingOption(value: "10", name: String(localized: "Balanced")),
                                  SettingOption(value: "2", name: String(localized: "Fine"))]) },
            get: { String(Int($0.ui.turnCoalesceGapSeconds.rounded())) },
            set: { s, v in if let x = Double(v), [30.0, 10, 2].contains(x) { s.ui.turnCoalesceGapSeconds = x } }),

        // C · Models
        textModel("textModelPicks.super", String(localized: "Text model for Super merge"),
                  get: { $0.ui.superTextModelID }, set: { $0.ui.superTextModelID = $1 }),
        textModel("textModelPicks.general", String(localized: "Text model for everything else"),
                  get: { $0.ui.textModelID }, set: { $0.ui.textModelID = $1 }),

        // E · Style
        choice(SettingID.tone.rawValue, .tone, SettingID.tone.label, PromptStore.Tone.self, name: \.settingsTitle,
               get: { $0.prompts.tone }, set: { $0.prompts.tone = $1 }),
        toggle("fillersVerbatim.removeFillers", .fillersVerbatim, String(localized: "Remove fillers"),
               get: { $0.prompts.removeFillers }, set: { $0.prompts.removeFillers = $1 }),
        toggle("fillersVerbatim.verbatim", .fillersVerbatim, String(localized: "Verbatim"),
               get: { $0.prompts.verbatim }, set: { $0.prompts.verbatim = $1 }),
        defaultsToggle(SettingID.benchmark.rawValue, .benchmark, String(localized: "Keep corrected lines as a benchmark"),
                       defaultsKey: Benchmark.enabledKey, default: true),

        // I · Dictation
        choice("dictationHotkey.hotkey", .dictationHotkey, String(localized: "Dictation hotkey"), DictationSettings.Hotkey.self, name: \.label,
               get: { $0.dictation.hotkey }, set: { $0.dictation.hotkey = $1 }),
        choice("dictationHotkey.mode", .dictationHotkey, String(localized: "Dictation mode"), DictationSettings.Mode.self, name: \.label,
               get: { $0.dictation.mode }, set: { $0.dictation.mode = $1 }),
        SettingAccessor(
            key: "dictationHotkey.pauseFlush", setting: .dictationHotkey, label: String(localized: "Dictation flush after a pause"),
            kind: { _ in .number(0.8 ... 4.0, step: 0.1, unit: "s") },
            get: { SettingKind.format($0.dictation.pauseFlushSeconds, step: 0.1) },
            set: { s, v in if let x = Double(v), (0.8 ... 4.0).contains(x) { s.dictation.pauseFlushSeconds = x } }),
        engine("dictationRecognition.engine", .dictationRecognition, String(localized: "Dictation engine"), options: liveEngines,
               get: { $0.dictation.engine }, set: { $0.dictation.engine = $1 }),
        SettingAccessor(
            key: "dictationRecognition.language", setting: .dictationRecognition, label: String(localized: "Dictation language"),
            kind: { _ in .choice([SettingOption(value: "auto", name: String(localized: "Auto-detect"))]
                                 + DictationSettings.languageOptions.map { SettingOption(value: $0, name: SettingsLanguageNames.name($0)) }) },
            get: { $0.dictation.languages.sorted().first ?? "auto" },
            set: { s, v in
                if v == "auto" { s.dictation.languages = [] }
                else if DictationSettings.languageOptions.contains(v) { s.dictation.languages = [v] }
            }),
        toggle("dictationCleanup.spokenCommands", .dictationCleanup, String(localized: "Dictation spoken commands"),
               get: { $0.dictation.spokenCommands }, set: { $0.dictation.spokenCommands = $1 }),
        toggle("dictationCleanup.destutter", .dictationCleanup, String(localized: "Dictation collapses fillers and stutters"),
               get: { $0.dictation.destutter }, set: { $0.dictation.destutter = $1 }),
        toggle("dictationCleanup.applyVocabulary", .dictationCleanup, String(localized: "Dictation applies vocabulary spellings"),
               get: { $0.dictation.applyVocabulary }, set: { $0.dictation.applyVocabulary = $1 }),
        choice("dictationFormatting.defaultMode", .dictationFormatting, String(localized: "Dictation in apps without a rule"),
               DictationSettings.FormatMode.self, name: \.label,
               get: { $0.dictation.defaultMode }, set: { $0.dictation.defaultMode = $1 }),
        toggle("dictationContext.readContext", .dictationContext, String(localized: "Dictation reads the text around the cursor"),
               get: { $0.dictation.readContext }, set: { $0.dictation.readContext = $1 }),
        toggle("dictationContext.selfCorrections", .dictationContext, String(localized: "Dictation applies spoken self-corrections"),
               get: { $0.dictation.selfCorrections }, set: { $0.dictation.selfCorrections = $1 }),
        toggle("dictationContext.languageFromContext", .dictationContext, String(localized: "Dictation follows the field's language"),
               get: { $0.dictation.languageFromContext }, set: { $0.dictation.languageFromContext = $1 }),
        toggle("dictationContext.livePreview", .dictationContext, String(localized: "Dictation live preview"),
               get: { $0.dictation.livePreview }, set: { $0.dictation.livePreview = $1 }),
        toggle("dictationContext.useLearnedTerms", .dictationContext, String(localized: "Dictation uses names learned from transcripts"),
               get: { $0.dictation.useLearnedTerms }, set: { $0.dictation.useLearnedTerms = $1 }),
        choice("dictationInsertion.spacing", .dictationInsertion, String(localized: "Dictation spacing"), DictationSettings.Spacing.self, name: \.label,
               get: { $0.dictation.spacing }, set: { $0.dictation.spacing = $1 }),
        toggle("dictationInsertion.restoreClipboard", .dictationInsertion, String(localized: "Dictation restores the clipboard"),
               get: { $0.dictation.restoreClipboard }, set: { $0.dictation.restoreClipboard = $1 }),
        toggle("dictationIndicators.showHUD", .dictationIndicators, String(localized: "Dictation status strip"),
               get: { $0.dictation.showHUD }, set: { $0.dictation.showHUD = $1 }),
        toggle("dictationIndicators.showMenuBar", .dictationIndicators, String(localized: "Dictation in the menu bar"),
               get: { $0.dictation.showMenuBar }, set: { $0.dictation.showMenuBar = $1 }),
        toggle("dictationIndicators.playSounds", .dictationIndicators, String(localized: "Dictation start / stop sounds"),
               get: { $0.dictation.playSounds }, set: { $0.dictation.playSounds = $1 }),
        toggle(SettingID.dictationLinks.rawValue, .dictationLinks, String(localized: "Allow transcriberr://dictate links"),
               get: { $0.dictation.urlActions }, set: { $0.dictation.urlActions = $1 }),
        toggle(SettingID.dictationHistory.rawValue, .dictationHistory, SettingID.dictationHistory.label,
               get: { $0.dictation.keepHistory }, set: { $0.dictation.keepHistory = $1 }),

        // J · Updates, K · AI assistants
        toggle(SettingID.updates.rawValue, .updates, String(localized: "Check for new versions once a day"),
               get: { $0.updates.autoCheck }, set: { $0.updates.autoCheck = $1 }),
    ]
}

// MARK: - A proposed change

struct SettingChange: Identifiable, Equatable {
    let key: String
    let label: String
    let from: String
    let to: String
    let fromName: String
    let toName: String

    var id: String { key }
    /// "Echo filter in meetings: On → Off"
    var summary: String { "\(label): \(fromName) \u{2192} \(toName)" }
}

/// What came back from the model, checked against the catalog.
struct SettingsAskResult: Equatable {
    var changes: [SettingChange] = []
    /// Settings the request named that already have that value.
    var unchanged: [String] = []
    /// Why parts of the answer were dropped, one sentence each.
    var dropped: [String] = []

    var isEmpty: Bool { changes.isEmpty }
}

enum SettingsAskError: LocalizedError, Equatable {
    case notJSON
    case model(String)

    var errorDescription: String? {
        switch self {
        case .notJSON: String(localized: "The text model's answer wasn't a list of settings, so nothing was changed. Try naming the setting, such as \u{201C}turn off the echo filter\u{201D}.")
        case .model(let why): String(localized: "The on-device text model couldn't answer: \(why)")
        }
    }
}

// MARK: - Prompt, parsing, validation

enum SettingsAsk {
    static let maxOutputTokens = 400

    static let systemPrompt = """
    You change the settings of Transcriberr, a Mac transcription app. You get a list of settings, one per line: \
    id | label | current value | allowed values | what it does. Then the person's request.
    Answer with ONLY a JSON array, no other text: [{"id": "<id>", "value": <value>}]. One entry per setting \
    the request asks to change. Use the ids exactly as listed. For on/off settings answer "on" or "off". For a \
    choice answer one of the allowed values (the part before the brackets). Change a setting only when the \
    request plainly asks for what the new value does; never switch something off to make it better. If the \
    request asks for nothing on the list, or you are unsure, answer [].
    """

    /// One line per accessor: id, label, current value, allowed values and
    /// the first sentence of the help, cut short.
    ///
    /// Labels, option names and help are in the interface language on
    /// purpose (5.8.0): the request is typed in that language, and the model
    /// matches "вимкни фільтр луни" to a Ukrainian label more surely than to
    /// an English one. The system prompt stays English, and the ids and
    /// values the model answers with are English in every language, so the
    /// parsing does not change.
    static func catalog(_ stores: SettingsStores, accessors: [SettingAccessor] = SettingAccessors.all) -> String {
        accessors.map { a in
            let kind = a.kind(stores)
            return [a.key, a.label, a.get(stores), kind.allowedSummary, shortHelp(a.setting)]
                .joined(separator: " | ")
        }.joined(separator: "\n")
    }

    static func userMessage(request: String, catalog: String) -> String {
        "SETTINGS:\n\(catalog)\n\nREQUEST: \(request.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    static func shortHelp(_ id: SettingID) -> String {
        let help = id.help
        let first = help.split(separator: ".", maxSplits: 1).first.map(String.init) ?? help
        return first.count > 120 ? String(first.prefix(117)) + "…" : first
    }

    /// The `[{id, value}]` pairs in the model's answer. Tolerates a code
    /// fence or a sentence around the array, and a `{"changes": [...]}`
    /// wrapper; anything else is `notJSON`.
    static func parse(_ answer: String) throws -> [(id: String, value: Any)] {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        func decode(_ s: Substring) -> Any? {
            guard let data = s.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        }
        var json: Any?
        if let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end {
            json = decode(text[start ... end])
        }
        if json == nil, let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            json = decode(text[start ... end])
        }
        let items: [Any]
        switch json {
        case let array as [Any]: items = array
        case let object as [String: Any]:
            if let inner = object["changes"] as? [Any] ?? object["settings"] as? [Any] { items = inner }
            else if object["id"] != nil { items = [object] }
            else { throw SettingsAskError.notJSON }
        default: throw SettingsAskError.notJSON
        }
        return items.compactMap { item in
            guard let o = item as? [String: Any],
                  let id = (o["id"] ?? o["setting"] ?? o["key"]) as? String,
                  let value = o["value"] else { return nil }
            return (id.trimmingCharacters(in: .whitespaces), value)
        }
    }

    /// A value naming a cloud engine, by its id or its display name
    /// ("openai", "OpenAI (GPT-4o)").
    private static func isCloudEngine(_ value: String) -> Bool {
        let folded = SettingsFilter.fold(value)
        return BackendFactory.Kind.allCases.contains { k in
            !k.isLocal && (SettingsFilter.fold(k.rawValue) == folded || SettingsFilter.fold(k.displayName) == folded
                           || folded.hasPrefix(SettingsFilter.fold(k.rawValue) + " ("))
        }
    }

    /// Checks each pair against the catalog: unknown ids, excluded
    /// settings and values the setting doesn't take are dropped with a
    /// reason; a later entry for the same setting wins.
    static func validate(_ pairs: [(id: String, value: Any)], stores: SettingsStores) -> SettingsAskResult {
        var result = SettingsAskResult()
        var order: [String] = []
        var proposed: [String: SettingChange] = [:]
        var same: [String: String] = [:]
        for (id, value) in pairs {
            guard let a = SettingAccessors.accessor(id) else {
                let base = SettingID(rawValue: String(id.split(separator: ".").first ?? ""))
                if let base, let why = SettingAccessors.exclusion(base) {
                    result.dropped.append(String(localized: "\(base.label) can't be changed by a request: \(why)"))
                } else {
                    result.dropped.append(String(localized: "There is no setting called \u{201C}\(id)\u{201D}, so that part was dropped."))
                }
                continue
            }
            let kind = a.kind(stores)
            guard let v = kind.normalize(value) else {
                if let raw = value as? String, isCloudEngine(raw) {
                    result.dropped.append(String(localized: "\(a.label) can't be switched to a cloud engine by a request: it sends recordings off this Mac, so it is picked by hand."))
                    continue
                }
                let allowed = kind.allowedForPeople
                if let shown = describe(value) {
                    result.dropped.append(String(localized: "\(a.label) can't be set to \(shown). It takes \(allowed)."))
                } else {
                    result.dropped.append(String(localized: "\(a.label) can't be set to that. It takes \(allowed)."))
                }
                continue
            }
            let current = a.get(stores)
            if !order.contains(a.key) { order.append(a.key) }
            if v == current {
                proposed[a.key] = nil
                same[a.key] = String(localized: "\(a.label) is already \(kind.displayName(v)).")
            } else {
                same[a.key] = nil
                proposed[a.key] = SettingChange(key: a.key, label: a.label, from: current, to: v,
                                                fromName: kind.displayName(current), toName: kind.displayName(v))
            }
        }
        result.changes = order.compactMap { proposed[$0] }
        result.unchanged = order.compactMap { same[$0] }
        return result
    }

    private static func describe(_ value: Any) -> String? {
        if let s = value as? String { return "\u{201C}\(s)\u{201D}" }
        if let n = value as? NSNumber { return SettingKind.isBool(value) ? (n.boolValue ? "true" : "false") : n.stringValue }
        return nil
    }

    // MARK: Apply and undo

    /// What Undo needs: the value of every key the changes touched (their
    /// coupled keys included), taken before they were applied.
    struct Snapshot: Equatable {
        let values: [(key: String, value: String)]
        static func == (a: Snapshot, b: Snapshot) -> Bool {
            a.values.map(\.key) == b.values.map(\.key) && a.values.map(\.value) == b.values.map(\.value)
        }
    }

    @discardableResult
    static func apply(_ changes: [SettingChange], stores: SettingsStores) -> Snapshot {
        var keys: [String] = []
        for c in changes {
            guard let a = SettingAccessors.accessor(c.key) else { continue }
            for k in [a.key] + a.coupled where !keys.contains(k) { keys.append(k) }
        }
        let snapshot = Snapshot(values: keys.compactMap { k in
            SettingAccessors.accessor(k).map { (k, $0.get(stores)) }
        })
        for c in changes {
            guard let a = SettingAccessors.accessor(c.key) else { continue }
            // Revalidate: the value must still be one the setting takes.
            guard a.kind(stores).normalize(c.to) == c.to else { continue }
            a.set(stores, c.to)
            didSet(a.key, to: c.to)
        }
        return snapshot
    }

    /// Puts back every value in the snapshot that differs now.
    static func undo(_ snapshot: Snapshot, stores: SettingsStores) {
        for (key, value) in snapshot.values {
            guard let a = SettingAccessors.accessor(key), a.get(stores) != value else { continue }
            a.set(stores, value)
            didSet(key, to: value)
        }
    }

    /// The side effects the on-screen control has besides storing the value.
    private static func didSet(_ key: String, to value: String) {
        guard !isTesting else { return }
        switch (key, value) {
        case (SettingID.calendarContext.rawValue, "on"):
            Task { _ = await MeetingContext.requestAccess(EKEventStore(), ask: true) }
        case (SettingID.benchmark.rawValue, "off"):
            Benchmark.cancelQueued()
        default: break
        }
    }

    private static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

// MARK: - The model call

/// The text model a request is sent to. Stubbed in tests.
protocol SettingsAskModel {
    func answer(system: String, user: String, maxTokens: Int) async throws -> String
}

/// The on-device text model (Settings → Models, "everything else"). A
/// request about settings never leaves the Mac, whatever the
/// post-processing engine is.
struct OnDeviceSettingsAskModel: SettingsAskModel {
    let factory: BackendFactory

    /// How long a request waits for the text model before giving up: a
    /// background Super run or Summary can hold it for minutes, and the
    /// person is looking at the panel.
    static let patience: TimeInterval = 5

    /// The whole request, a first model load included. One answer took
    /// 123 s instead of the usual 10; the person should not
    /// watch "thinking" for that long.
    static let deadline: TimeInterval = 60

    struct TookTooLong: LocalizedError {
        var errorDescription: String? { String(localized: "it took longer than a minute, so nothing was changed. Try again, or change the setting by hand.", comment: "Ends the sentence: The on-device text model couldn't answer: …") }
    }

    func answer(system: String, user: String, maxTokens: Int) async throws -> String {
        let backend = factory.backend(for: .localText)
        return try await Deadline.run(seconds: Self.deadline, timeoutError: TookTooLong()) {
            if !(await backend.isReady) { try await backend.load(modelPath: nil) }
            // Set inside: Deadline runs the work detached, without the
            // caller's task-locals.
            return try await GenerationQueue.$interactive.withValue(true) {
                try await GenerationQueue.$patience.withValue(Self.patience) {
                    try await backend.generateText(systemInstruction: system, userMessage: user, maxTokens: maxTokens)
                }
            }
        }
    }
}

extension SettingsAsk {
    /// Why a request about something a request can't touch changed nothing:
    /// those settings aren't in the catalog, so the model only finds nothing.
    static func handOnlyReason(_ request: String) -> String? {
        let text = SettingsFilter.fold(request)
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        if has("openai", "chatgpt", "gpt", "anthropic", "claude", "gemini", "cloud") {
            return has("api key", "key") ? String(localized: "API keys are only typed by hand, in Settings under API keys.")
                : String(localized: "Cloud engines send your recordings or transcripts off this Mac, so they are picked by hand in Settings under Engines.")
        }
        if has("api key") { return String(localized: "API keys are only typed by hand, in Settings under API keys.") }
        if has("assistant", "mcp") { return String(localized: "Access to your library is granted by hand, in Settings under AI assistants.") }
        return nil
    }

    /// Request → model → checked changes.
    static func ask(_ request: String, stores: SettingsStores, model: some SettingsAskModel) async throws -> SettingsAskResult {
        let answer: String
        do {
            answer = try await model.answer(system: systemPrompt,
                                            user: userMessage(request: request, catalog: catalog(stores)),
                                            maxTokens: maxOutputTokens)
        } catch {
            throw SettingsAskError.model(error.localizedDescription)
        }
        var result = validate(try parse(answer), stores: stores)
        if result.changes.isEmpty, result.unchanged.isEmpty, result.dropped.isEmpty, let why = handOnlyReason(request) {
            result.dropped.append(why)
        }
        return result
    }
}
