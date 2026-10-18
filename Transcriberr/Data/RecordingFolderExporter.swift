import Foundation
import CryptoKit

/// Everything about one recording in a plain folder: the transcript as it
/// is now (.txt/.srt/.json, the same sidecars as beside the audio), every
/// saved version, every output with its earlier ones and the prompt and
/// engine that made each, the presets' current prompts, optionally the
/// audio, and a manifest with a SHA-256 per file. Markdown and JSON only,
/// so it opens anywhere and nothing of it depends on this app.
enum RecordingFolderExporter {
    struct Manifest: Codable, Equatable {
        struct File: Codable, Equatable {
            var path: String
            var bytes: Int
            var sha256: String
        }
        var app: String
        var exportedAt: Date
        var recordingId: UUID
        var title: String
        var includesAudio: Bool
        var files: [File]
    }

    /// Writes `<parent>/<title> (<date>)/` and returns it. An existing
    /// folder of that name gets a number, never overwritten.
    @MainActor
    static func export(_ recording: Recording, presets: PresetStore, to parent: URL,
                       includeAudio: Bool, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let date = Date(timeIntervalSince1970: Double(recording.createdAtMillis) / 1000)
        let base = safe("\(recording.title) (\(dayFormatter.string(from: date)))")
        var root = parent.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: root.path) {
            root = parent.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // Transcript, as now.
        let transcriptDir = root.appendingPathComponent("transcript", isDirectory: true)
        try fm.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        try TranscriptExporter.export(recording: recording, to: transcriptDir)

        // Saved transcript versions.
        guard let context = recording.modelContext else {
            throw NSError(domain: "Export", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "The recording is no longer in the library."])
        }
        let repo = RecordingRepository(context: context)
        let versions = recording.versions.sorted { $0.createdAtMillis < $1.createdAtMillis }
        if !versions.isEmpty {
            let dir = root.appendingPathComponent("versions", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for (i, v) in versions.enumerated() {
                let body = repo.decodeVersion(v).map { seg in
                    let name = seg.speakerName ?? seg.speaker
                    return "[\(TranscriptExporter.srtTime(seg.start))] " + (name.map { "\($0): " } ?? "") + seg.text
                }.joined(separator: "\n\n")
                let head = "# \(recording.title)\n\n\(v.engineLabel) · \(stamp(v.createdAtMillis)) · \(v.segmentCount) segments\n\n"
                try write(head + body, to: dir.appendingPathComponent(
                    safe(String(format: "%02d %@ %@", i + 1, fileStamp(v.createdAtMillis), v.engineLabel)) + ".md"))
            }
        }

        // Outputs, current and earlier, each with what made it.
        let presetIds = Set(recording.outputs.map(\.presetId) + recording.outputVersions.map(\.presetId))
        if !presetIds.isEmpty {
            let dir = root.appendingPathComponent("outputs", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for id in presetIds.sorted() {
                let current = recording.outputs.first { $0.presetId == id }
                let title = current?.title ?? presets.preset(id)?.outputTitle ?? id
                if let current {
                    try write("# \(title)\n\n\(current.markdown)\n", to: dir.appendingPathComponent(safe(title) + ".md"))
                }
                let earlier = repo.outputVersions(presetId: id, in: recording)
                    .filter { $0.markdown != current?.markdown }
                    .sorted { $0.createdAtMillis < $1.createdAtMillis }
                guard !earlier.isEmpty else { continue }
                let hist = dir.appendingPathComponent("history", isDirectory: true)
                try fm.createDirectory(at: hist, withIntermediateDirectories: true)
                for v in earlier {
                    try write(versionMarkdown(v, title: title), to: hist.appendingPathComponent(
                        safe("\(fileStamp(v.createdAtMillis)) \(title)") + ".md"))
                }
            }
            // The current output's own record, prompt included.
            for id in presetIds.sorted() {
                guard let current = recording.outputs.first(where: { $0.presetId == id }),
                      let v = recording.outputVersions.first(where: { $0.presetId == id && $0.markdown == current.markdown }),
                      v.userPrompt != nil else { continue }
                let prompts = dir.appendingPathComponent("prompts used", isDirectory: true)
                try fm.createDirectory(at: prompts, withIntermediateDirectories: true)
                try write(versionMarkdown(v, title: current.title), to: prompts.appendingPathComponent(safe(current.title) + ".md"))
            }
        }

        // The presets' prompts as they are now, for the presets used here.
        let used = presets.presets.filter { presetIds.contains($0.id) }
        if !used.isEmpty {
            let dir = root.appendingPathComponent("presets", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for p in used {
                let body = """
                # \(p.name)

                Runs as: \(p.kind == .rewrite ? "rewrite (the whole transcript, one window at a time)" : "analysis (the whole transcript at once)")

                ## System

                \(p.systemTemplate)

                ## User template

                \(p.userTemplate)

                """
                try write(body, to: dir.appendingPathComponent(safe(p.name) + ".md"))
            }
        }

        if includeAudio {
            let dir = root.appendingPathComponent("audio", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let main = URL(fileURLWithPath: recording.audioPath)
            var sources = [main]
            for kind in ["mic", "sys"] {
                if let s = AudioCompressor.sidecarURL(for: main, kind: kind) { sources.append(s) }
            }
            for src in sources where fm.fileExists(atPath: src.path) {
                try fm.copyItem(at: src, to: dir.appendingPathComponent(src.lastPathComponent))
            }
        }

        let manifest = Manifest(
            app: "Transcriberr " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""),
            exportedAt: now, recordingId: recording.id, title: recording.title,
            includesAudio: includeAudio, files: try files(in: root))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        return root
    }

    private static func versionMarkdown(_ v: OutputVersion, title: String) -> String {
        var s = "# \(title)\n\n\(stamp(v.createdAtMillis))"
        if let e = v.engineLabel { s += " · \(e)" }
        s += "\n\n\(v.markdown)\n"
        if let user = v.userPrompt {
            s += "\n---\n\n## Prompt used\n\n### System\n\n\(v.systemPrompt ?? "")\n\n### User template\n\n\(user)\n"
        }
        return s
    }

    /// Every file under `root`, relative paths, sorted, hashed.
    static func files(in root: URL) throws -> [Manifest.File] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [Manifest.File] = []
        let prefix = root.standardizedFileURL.path + "/"
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let path = url.standardizedFileURL.path.replacingOccurrences(of: prefix, with: "")
            out.append(.init(path: path, bytes: data.count,
                             sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        }
        return out.sorted { $0.path < $1.path }
    }

    private static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A file name from any title: no slashes or colons, not hidden, short.
    static func safe(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines).union(.controlCharacters)
        var s = name.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty { s = "Untitled" }
        return String(s.prefix(120))
    }

    private static func stamp(_ millis: Int64) -> String {
        stampFormatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
    }

    private static func fileStamp(_ millis: Int64) -> String {
        fileStampFormatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy, HH:mm"; return f
    }()
    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"; return f
    }()
}
