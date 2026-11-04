import SwiftUI

/// In-window settings (selected from the sidebar). Wraps the existing
/// macOS-Settings-scene tabs in Sheet so the look stays consistent with
/// the rest of the app.
///
/// A search field and a Normal / Advanced switch sit at the top. Which
/// settings show is decided by `SettingsFilter` (SettingsCatalog.swift),
/// handed to every section through the environment.
struct SettingsScreen: View {
    @Environment(AppContainer.self) private var container
    /// Letters of the sections folded away, kept between launches. Style &
    /// vocabulary starts folded: it is the longest and the least visited.
    @AppStorage("settings.collapsed") private var collapsedRaw = "E"
    @AppStorage(SettingsLevel.storageKey) private var levelRaw = SettingsLevel.normal.rawValue
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }
    private var level: SettingsLevel { SettingsLevel(rawValue: levelRaw) ?? .normal }
    private var filter: SettingsFilter { SettingsFilter(level: level, query: query) }

    private func toggle(_ key: String) {
        var c = collapsed
        if c.contains(key) { c.remove(key) } else { c.insert(key) }
        collapsedRaw = c.sorted().joined(separator: ",")
    }

    var body: some View {
        let filter = filter
        let sections = filter.visibleSections
        Sheet {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    BrandStrip {
                        Text("On-device").uiLabel(9, color: AppColor.ink3)
                    }
                    .padding(.horizontal, AppMetric.sheetPadding)
                    .padding(.top, AppMetric.sheetVerticalPadding)
                    .id("top")

                    Spacer().frame(height: AppMetric.sheetVerticalPadding)
                    InkRule()
                    Spacer().frame(height: AppMetric.l)

                    SectionIndex(5, "Settings",
                                 summary: "Per-recording overrides live in the Library detail Run sheet. Everything here is global defaults.")
                        .padding(.horizontal, AppMetric.sheetPadding)

                    Spacer().frame(height: AppMetric.l)

                    controls(filter, sections: sections)
                        .padding(.horizontal, AppMetric.sheetPadding)

                    if sections.isEmpty {
                        noMatch
                            .padding(.horizontal, AppMetric.sheetPadding)
                            .padding(.top, AppMetric.l)
                    }

                    ForEach(Array(sections.enumerated()), id: \.element) { index, section in
                        sectionBlock(section, letter: Self.letter(index), filter: filter)
                    }
                }
                .padding(.bottom, AppMetric.xl)
                .environment(\.settingsFilter, filter)
            }
            .onChange(of: container.modelsPaneRequested) { _, _ in showModels(proxy) }
            .task { if container.pendingModelsScroll { showModels(proxy) } }
            .background {
                // ⌘F: to the field, wherever the screen is scrolled.
                Button("Search settings") {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("top", anchor: .top) }
                    searchFocused = true
                }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
            }
        }
    }

    /// Letters follow the sections on screen, so Normal and a search read
    /// A, B, C… without gaps.
    static func letter(_ index: Int) -> String {
        String(UnicodeScalar(UInt8(65 + index % 26)))
    }

    // MARK: - Search and level

    @ViewBuilder
    private func controls(_ filter: SettingsFilter, sections: [SettingsSection]) -> some View {
        VStack(alignment: .leading, spacing: AppMetric.s) {
            HStack(alignment: .bottom, spacing: AppMetric.m) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Find a setting").uiLabel(9, color: AppColor.ink2)
                    SettingsSearchField(query: $query, focused: $searchFocused)
                }
                .frame(maxWidth: 420)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Show").uiLabel(9, color: AppColor.ink2)
                    HStack(spacing: 6) {
                        ForEach(SettingsLevel.allCases, id: \.self) { l in
                            LitChip(label: l.title, active: level == l) { levelRaw = l.rawValue }
                                .accessibilityAddTraits(level == l ? .isSelected : [])
                                .help(l == .normal
                                      ? "The settings most people change"
                                      : "Everything, including Super tuning, prompts, voices and API keys")
                        }
                    }
                }
            }
            Text(caption(filter, sections: sections))
                .font(AppFont.text(12))
                .foregroundStyle(AppColor.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private func caption(_ filter: SettingsFilter, sections: [SettingsSection]) -> String {
        guard filter.isSearching else {
            return level == .normal
                ? "Showing the settings most people change. Advanced adds Super tuning, prompts, voices, learned terms, API keys and AI assistants."
                : "Showing every setting."
        }
        let matches = sections.flatMap { filter.visible(in: $0) }
        guard !matches.isEmpty else { return "Search covers Normal and Advanced settings." }
        let count = matches.count == 1 ? "1 setting matches" : "\(matches.count) settings match"
        let scope = sections.count == 1 ? "" : " in \(sections.count) sections"
        let advanced = sections.flatMap { filter.advancedMatches(in: $0) }.count
        let tail: String
        switch advanced {
        case 0: tail = "."
        case matches.count: tail = matches.count == 1 ? ", an Advanced one." : ", all of them Advanced."
        default: tail = ", \(advanced) of them Advanced."
        }
        return count + scope + tail
    }

    private var noMatch: some View {
        VStack(alignment: .leading, spacing: AppMetric.s) {
            Text("No setting matches \u{201C}\(query.trimmingCharacters(in: .whitespaces))\u{201D}, in Normal or Advanced. Try one word, such as microphone, Whisper or hotkey.")
                .font(AppFont.text(14))
                .foregroundStyle(AppColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520, alignment: .leading)
            TapButton { query = "" } label: {
                LitButtonChrome(.secondary, compact: true) { Text("Clear search") }
            }
        }
    }

    /// Unfold Models and bring it into view (the text-model prompt). A
    /// search is cleared first: it could be hiding Models.
    private func showModels(_ proxy: ScrollViewProxy) {
        container.pendingModelsScroll = false
        query = ""
        let key = SettingsSection.models.rawValue
        if collapsed.contains(key) { toggle(key) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(key, anchor: .top) }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func content(_ section: SettingsSection, _ filter: SettingsFilter) -> some View {
        // Embedded Form/List tabs need explicit heights (they collapse
        // inside a ScrollView) and hidden system backgrounds (white grouped
        // chrome clashes with the surrounding base fill). The height shrinks
        // with the settings that show.
        let height = filter.formHeight(for: section)
        switch section {
        case .audio:
            RecorderSettingsTab()
        case .engines:
            EnginesSettingsTab().scrollContentBackground(.hidden).frame(minHeight: height)
        case .models:
            ModelsSettingsTab()
        case .presets:
            PresetsSettingsTab()
        case .style:
            StyleSettingsTab().scrollContentBackground(.hidden).frame(minHeight: height)
        case .snippets:
            SnippetsSettingsTab().scrollContentBackground(.hidden).frame(minHeight: height)
        case .prompts:
            PromptsSettingsTab().scrollContentBackground(.hidden).frame(minHeight: height)
        case .apiKeys:
            APIKeysSettingsTab().scrollContentBackground(.hidden).frame(minHeight: height)
        case .dictation:
            DictationSettingsTab().scrollContentBackground(.hidden).frame(minHeight: height)
        case .updates:
            UpdatesSettingsTab().scrollContentBackground(.hidden).frame(minHeight: height)
        case .assistants:
            AssistantsSettingsSection()
        }
    }

    @ViewBuilder
    private func sectionBlock(_ section: SettingsSection, letter: String, filter: SettingsFilter) -> some View {
        let key = section.rawValue
        let label = section.title
        // A search opens every section with a match and leaves the saved
        // folds alone, so clearing it restores the screen as it was.
        let searching = filter.isSearching
        let open = searching || !collapsed.contains(key)
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: AppMetric.l)
            InkRule()
            // While searching every section with a match is open, and a tap
            // does nothing (disabling it would dim the header).
            TapButton {
                guard !searching else { return }
                withAnimation(.easeOut(duration: 0.15)) { toggle(key) }
            } label: {
                HStack(spacing: 0) {
                    Text("\(letter) · ")
                        .uiLabel(11, color: AppColor.accentOnLight)
                    Text(label)
                        .uiLabel(11)
                    Spacer()
                    if !searching {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AppColor.ink3)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                .padding(.horizontal, AppMetric.sheetPadding)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .help(searching ? label : open ? "Fold \(label) away" : "Show \(label)")
            .accessibilityValue(open ? "expanded" : "collapsed")
            if open {
                HairlineSoft()
                advancedNote(filter.advancedMatches(in: section))
                Spacer().frame(height: 12)
                content(section, filter)
                    .padding(.horizontal, AppMetric.sheetPadding)
            }
        }
        .id(key)
    }

    /// Under a section's header while searching in Normal: which of the
    /// matches below are Advanced settings.
    @ViewBuilder
    private func advancedNote(_ ids: [SettingID]) -> some View {
        if !ids.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: AppMetric.s) {
                Text("Advanced").uiLabel(9, color: AppColor.accentOnLight)
                Text(ids.count == 1
                     ? "\(ids[0].label) is an Advanced setting, shown because it matches."
                     : "\(ids.map(\.label).joined(separator: ", ")) are Advanced settings, shown because they match.")
                    .font(AppFont.text(12))
                    .foregroundStyle(AppColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, AppMetric.sheetPadding)
            .padding(.top, AppMetric.s)
        }
    }
}

/// The search field: Lit Field control anatomy (white control ground, a
/// 1px control border, 10pt radius) with the accent focus ring. Escape
/// clears it.
private struct SettingsSearchField: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: AppMetric.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppColor.ink3)
                .accessibilityHidden(true)
            TextField("Search settings", text: $query, prompt: Text("Microphone, Whisper, hotkey…"))
                .textFieldStyle(.plain)
                .font(AppFont.text(14))
                .foregroundStyle(AppColor.ink)
                .focused(focused)
                .focusEffectDisabled()
                .onExitCommand { query = "" }
                .accessibilityLabel("Search settings")
            if !query.isEmpty {
                TapButton { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(AppColor.ink3)
                        .frame(width: 24, height: 24)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, AppMetric.m)
        .frame(height: 36)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(focused.wrappedValue ? AppColor.ink2 : AppColor.controlBorder, lineWidth: 1)
                )
        }
        .overlay {
            if focused.wrappedValue {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(AppColor.accentOnLight, lineWidth: 2)
                    .padding(-3)
            }
        }
    }
}
