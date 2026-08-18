import Foundation
import SwiftData

/// Read-only access to the Transcriberr knowledge base for external callers
/// (CLI `kb …` subcommands and the MCP server).
///
/// Opens the SAME store file as the GUI app but with `allowsSave: false`,
/// which maps to Core Data's read-only store option: this process can never
/// write to or migrate a store the GUI has open, and WAL guarantees
/// consistent snapshot reads across processes. A fresh ModelContext is
/// created per request so a long-running MCP server sees the GUI's newest
/// committed writes.
struct KBService {
    enum KBError: LocalizedError {
        case storeNotFound(path: String)
        case openFailed(underlying: String)
        case recordingNotFound(String)
        case ambiguousID(String, matches: [String])

        var errorDescription: String? {
            switch self {
            case .storeNotFound(let path):
                return "No Transcriberr database at \(path). Launch Transcriberr.app first."
            case .openFailed(let underlying):
                return "Could not open the database (\(underlying)). "
                    + "If Transcriberr was just updated, launch Transcriberr.app once "
                    + "to update the database, then retry."
            case .recordingNotFound(let id):
                return "No recording matches '\(id)'. Use kb list or kb search to find ids."
            case .ambiguousID(let id, let matches):
                return "'\(id)' matches several recordings: \(matches.joined(separator: ", ")). "
                    + "Use more characters of the id."
            }
        }
    }

    private let container: ModelContainer

    static func defaultStoreURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["TRANSCRIBERR_STORE"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriberr.store")
    }

    static func openReadOnly(at url: URL? = nil) throws -> KBService {
        let storeURL = url ?? defaultStoreURL()
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            throw KBError.storeNotFound(path: storeURL.path)
        }
        let schema = Schema(TranscriberrSchema.models)
        let config = ModelConfiguration("Transcriberr", schema: schema,
                                        url: storeURL, allowsSave: false)
        do {
            let container = try ModelContainer(for: schema, configurations: config)
            return KBService(container: container)
        } catch {
            throw KBError.openFailed(underlying: String(describing: error))
        }
    }

    private var storeURL: URL {
        container.configurations.first?.url ?? Self.defaultStoreURL()
    }

    // MARK: - Formatting helpers

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static func isoDate(_ millis: Int64) -> String {
        iso.string(from: Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
    }

    /// Accepts ISO8601 or a relative "7d"/"24h"/"90m" style suffix.
    static func parseSince(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let date = iso.date(from: s) { return date }
        let scales: [Character: TimeInterval] = ["d": 86_400, "h": 3_600, "m": 60, "w": 604_800]
        if let unit = s.last, let scale = scales[unit],
           let n = Double(s.dropLast()), n > 0 {
            return Date(timeIntervalSinceNow: -n * scale)
        }
        return nil
    }

    private func summary(_ rec: Recording) -> KBRecordingSummary {
        KBRecordingSummary(
            id: rec.id.uuidString,
            title: rec.title,
            createdAt: Self.isoDate(rec.createdAtMillis),
            durationSeconds: rec.durationSeconds,
            language: rec.sourceLanguage,
            folder: rec.folder?.name,
            tags: rec.tags.map(\.name).sorted(),
            segmentCount: rec.segments.count,
            outputPresets: rec.outputs.map(\.presetId).sorted()
        )
    }

    private func segmentDTO(_ seg: Segment) -> KBSegment {
        KBSegment(start: seg.startSeconds, end: seg.endSeconds, text: seg.text,
                  speaker: seg.speaker, speakerName: seg.speakerName)
    }

    private func fetchAll(_ context: ModelContext) throws -> [Recording] {
        try context.fetch(FetchDescriptor<Recording>(
            sortBy: [.init(\.createdAtMillis, order: .reverse)]))
    }

    // MARK: - Queries

    func list(folder: String? = nil, tag: String? = nil,
              since: Date? = nil, limit: Int = 25) throws -> [KBRecordingSummary] {
        let context = ModelContext(container)
        var rows = try fetchAll(context)
        if let folder {
            rows = rows.filter {
                $0.folder?.name.caseInsensitiveCompare(folder) == .orderedSame
            }
        }
        if let tag {
            rows = rows.filter { rec in
                rec.tags.contains { $0.name.caseInsensitiveCompare(tag) == .orderedSame }
            }
        }
        if let since {
            let cutoff = Int64(since.timeIntervalSince1970 * 1000)
            rows = rows.filter { $0.createdAtMillis >= cutoff }
        }
        return rows.prefix(max(1, limit)).map(summary)
    }

    func search(_ query: String, limit: Int = 20,
                matchesPerRecording: Int = 5) throws -> [KBSearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let context = ModelContext(container)
        // Single segment-table predicate (translates to SQL LIKE) instead of
        // walking every recording's relationship in memory.
        let segments = try context.fetch(FetchDescriptor<Segment>(
            predicate: #Predicate { $0.text.localizedStandardContains(q) }))
        var byRecording: [UUID: [Segment]] = [:]
        for seg in segments {
            guard let rec = seg.recording else { continue }
            byRecording[rec.id, default: []].append(seg)
        }
        var hits: [KBSearchHit] = []
        for rec in try fetchAll(context) {
            let matched = (byRecording[rec.id] ?? [])
                .sorted { $0.startSeconds < $1.startSeconds }
            let titleMatched = rec.title.localizedStandardContains(q)
            guard titleMatched || !matched.isEmpty else { continue }
            hits.append(KBSearchHit(
                recording: summary(rec),
                matches: matched.prefix(matchesPerRecording).map(segmentDTO),
                titleMatched: titleMatched))
        }
        return Array(hits.prefix(max(1, limit)))
    }

    /// Full UUID, or a case-insensitive id prefix (≥4 chars) unique among
    /// recordings.
    func resolve(idOrPrefix: String, context: ModelContext) throws -> Recording {
        let raw = idOrPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = try fetchAll(context)
        if let uuid = UUID(uuidString: raw),
           let exact = all.first(where: { $0.id == uuid }) {
            return exact
        }
        guard raw.count >= 4 else { throw KBError.recordingNotFound(raw) }
        let prefix = raw.uppercased()
        let matches = all.filter { $0.id.uuidString.hasPrefix(prefix) }
        switch matches.count {
        case 1: return matches[0]
        case 0: throw KBError.recordingNotFound(raw)
        default:
            throw KBError.ambiguousID(raw, matches: matches.map {
                "\($0.id.uuidString.prefix(8)) (\($0.title))"
            })
        }
    }

    func transcript(id: String, startSeconds: Double? = nil, endSeconds: Double? = nil,
                    offset: Int = 0, limit: Int = 200) throws -> KBTranscript {
        let context = ModelContext(container)
        let rec = try resolve(idOrPrefix: id, context: context)
        var segments = rec.segments.sorted { $0.startSeconds < $1.startSeconds }
        if let startSeconds {
            segments = segments.filter { $0.endSeconds >= startSeconds }
        }
        if let endSeconds {
            segments = segments.filter { $0.startSeconds <= endSeconds }
        }
        let total = segments.count
        let from = max(0, offset)
        let page = segments.dropFirst(from).prefix(max(1, limit))
        return KBTranscript(
            recording: summary(rec),
            segments: page.map(segmentDTO),
            totalSegments: total,
            offset: from,
            truncated: from + page.count < total)
    }

    func outputs(id: String, presetId: String? = nil) throws -> [KBOutput] {
        let context = ModelContext(container)
        let rec = try resolve(idOrPrefix: id, context: context)
        return rec.outputs
            .filter { presetId == nil || $0.presetId == presetId }
            .sorted { $0.createdAtMillis > $1.createdAtMillis }
            .map {
                KBOutput(presetId: $0.presetId, title: $0.title,
                         createdAt: Self.isoDate($0.createdAtMillis),
                         markdown: $0.markdown)
            }
    }

    func folders() throws -> [KBFolderInfo] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<Folder>(
            sortBy: [.init(\.sortOrder), .init(\.name)]))
            .map { KBFolderInfo(name: $0.name, count: $0.recordings.count) }
    }

    func tags() throws -> [KBTagInfo] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<Tag>(sortBy: [.init(\.name)]))
            .map { KBTagInfo(name: $0.name, count: $0.recordings.count) }
    }

    func stats() throws -> KBStats {
        let context = ModelContext(container)
        let all = try fetchAll(context)
        var languages: [String: Int] = [:]
        for rec in all {
            if let lang = rec.sourceLanguage, !lang.isEmpty {
                languages[lang, default: 0] += 1
            }
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: storeURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return KBStats(
            recordings: all.count,
            totalDurationSeconds: all.reduce(0) { $0 + $1.durationSeconds },
            languages: languages,
            folders: try context.fetchCount(FetchDescriptor<Folder>()),
            tags: try context.fetchCount(FetchDescriptor<Tag>()),
            outputs: try context.fetchCount(FetchDescriptor<OutputDoc>()),
            oldest: all.last.map { Self.isoDate($0.createdAtMillis) },
            newest: all.first.map { Self.isoDate($0.createdAtMillis) },
            storePath: storeURL.path,
            storeSizeBytes: size)
    }
}
