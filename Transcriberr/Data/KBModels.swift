import Foundation

// DTOs + renderers for the read-only knowledge-base layer (CLI `kb …` and
// the MCP server). Stable, documented JSON shape: Codable, camelCase keys,
// ISO8601 UTC dates, `schemaVersion` in every top-level envelope, and
// `.sortedKeys` encoding (JSONEncoder's default key order is not stable
// across encodes — see RecordingRepository.snapshotVersion).

enum KBSchema {
    static let version = 1
}

struct KBRecordingSummary: Codable {
    let id: String              // UUID string
    let title: String
    let createdAt: String       // ISO8601
    let durationSeconds: Double
    let language: String?
    let folder: String?
    let tags: [String]
    let segmentCount: Int
    /// Preset ids with a stored OutputDoc ("summary", "minutes", …) — tells
    /// the caller what kb_get_outputs will yield without another round trip.
    let outputPresets: [String]
}

struct KBSegment: Codable {
    let start: Double
    let end: Double
    let text: String
    let speaker: String?
    let speakerName: String?
}

struct KBTranscript: Codable {
    let recording: KBRecordingSummary
    let segments: [KBSegment]
    let totalSegments: Int
    let offset: Int
    let truncated: Bool
}

struct KBOutput: Codable {
    let presetId: String
    let title: String
    let createdAt: String
    let markdown: String
}

struct KBSearchHit: Codable {
    let recording: KBRecordingSummary
    let matches: [KBSegment]    // capped per recording
    let titleMatched: Bool
}

struct KBFolderInfo: Codable {
    let name: String
    let count: Int
}

struct KBTagInfo: Codable {
    let name: String
    let count: Int
}

struct KBStats: Codable {
    let recordings: Int
    let totalDurationSeconds: Double
    let languages: [String: Int]
    let folders: Int
    let tags: Int
    let outputs: Int
    let oldest: String?
    let newest: String?
    let storePath: String
    let storeSizeBytes: Int64
}

// MARK: - JSON encoding

enum KBJSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }()

    /// `{"schemaVersion":1, "<key>": <payload>}` envelope.
    static func envelope(_ key: String, _ payload: some Encodable) throws -> String {
        let data = try encoder.encode(
            KBEnvelope(schemaVersion: KBSchema.version, key: key, payload: payload))
        return String(decoding: data, as: UTF8.self)
    }
}

private struct KBEnvelope<T: Encodable>: Encodable {
    let schemaVersion: Int
    let key: String
    let payload: T

    struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try c.encode(schemaVersion, forKey: DynamicKey(stringValue: "schemaVersion"))
        try c.encode(payload, forKey: DynamicKey(stringValue: key))
    }
}

// MARK: - Rendering

enum KBRender {
    static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    static func line(_ seg: KBSegment, timestamps: Bool = true) -> String {
        let who = (seg.speakerName ?? seg.speaker).map { "\($0): " } ?? ""
        let ts = timestamps ? "[\(timestamp(seg.start))] " : ""
        return "\(ts)\(who)\(seg.text)"
    }

    static func headerLine(_ r: KBRecordingSummary) -> String {
        var bits = ["`\(String(r.id.prefix(8)))`", r.createdAt,
                    timestamp(r.durationSeconds)]
        if let lang = r.language, !lang.isEmpty { bits.append(lang.uppercased()) }
        if let folder = r.folder { bits.append("▸ \(folder)") }
        if !r.tags.isEmpty { bits.append(r.tags.map { "#\($0)" }.joined(separator: " ")) }
        if !r.outputPresets.isEmpty {
            bits.append("outputs: \(r.outputPresets.joined(separator: ", "))")
        }
        return bits.joined(separator: " · ")
    }

    static func markdownList(_ rows: [KBRecordingSummary]) -> String {
        guard !rows.isEmpty else { return "No recordings match." }
        return rows.map { "- **\($0.title)** — \(headerLine($0))" }
            .joined(separator: "\n")
    }

    static func markdown(_ t: KBTranscript, timestamps: Bool = true) -> String {
        var out = "## \(t.recording.title)\n\(headerLine(t.recording))\n\n"
        out += t.segments.map { line($0, timestamps: timestamps) }.joined(separator: "\n")
        out += "\n\n" + paginationFooter(t)
        return out
    }

    static func plainText(_ t: KBTranscript, timestamps: Bool = false) -> String {
        var out = t.segments.map { line($0, timestamps: timestamps) }.joined(separator: "\n")
        if t.truncated { out += "\n\n" + paginationFooter(t) }
        return out
    }

    private static func paginationFooter(_ t: KBTranscript) -> String {
        guard t.truncated || t.offset > 0 else {
            return "(\(t.totalSegments) segments, complete)"
        }
        let last = t.offset + t.segments.count
        var footer = "(segments \(t.offset)–\(max(t.offset, last - 1)) of \(t.totalSegments)"
        if last < t.totalSegments { footer += " — call again with offset: \(last)" }
        return footer + ")"
    }

    static func markdown(_ hits: [KBSearchHit], query: String) -> String {
        guard !hits.isEmpty else { return "No matches for \"\(query)\"." }
        return hits.map { hit in
            var out = "### \(hit.recording.title)\n\(headerLine(hit.recording))"
            if hit.titleMatched { out += " · title match" }
            if !hit.matches.isEmpty {
                out += "\n" + hit.matches.map { "- \(line($0))" }.joined(separator: "\n")
            }
            return out
        }.joined(separator: "\n\n")
    }

    static func markdown(_ outputs: [KBOutput]) -> String {
        guard !outputs.isEmpty else {
            return "No generated outputs stored. Use kb_get_transcript for the raw transcript."
        }
        return outputs.map {
            "## \($0.title) (\($0.presetId), \($0.createdAt))\n\n\($0.markdown)"
        }.joined(separator: "\n\n---\n\n")
    }

    static func markdown(folders: [KBFolderInfo], tags: [KBTagInfo]) -> String {
        var out = "## Folders\n"
        out += folders.isEmpty ? "(none)"
            : folders.map { "- \($0.name) (\($0.count))" }.joined(separator: "\n")
        out += "\n\n## Tags\n"
        out += tags.isEmpty ? "(none)"
            : tags.map { "- #\($0.name) (\($0.count))" }.joined(separator: "\n")
        return out
    }

    static func markdown(_ s: KBStats) -> String {
        var out = """
        ## Knowledge base
        - Recordings: \(s.recordings)
        - Total audio: \(timestamp(s.totalDurationSeconds))
        - Folders: \(s.folders) · Tags: \(s.tags) · Generated outputs: \(s.outputs)
        """
        if !s.languages.isEmpty {
            let langs = s.languages.sorted { $0.value > $1.value }
                .map { "\($0.key) (\($0.value))" }.joined(separator: ", ")
            out += "\n- Languages: \(langs)"
        }
        if let oldest = s.oldest, let newest = s.newest {
            out += "\n- Range: \(oldest) → \(newest)"
        }
        out += "\n- Store: \(s.storePath) (\(s.storeSizeBytes / 1024) KB)"
        return out
    }
}
