import Foundation

// `transcriberrcli mcp` — Model Context Protocol server over stdio.
//
// Hand-rolled JSON-RPC 2.0: the official swift-sdk needs a Swift 6 toolchain
// manifest while this project builds in Swift 5 language mode, and the
// surface we need is five methods. Newline-delimited requests on stdin,
// single-line responses on stdout. NOTHING else may write to stdout —
// AppLog goes to os_log + file, and every KB code path is print-free;
// diagnostics here go to stderr.
//
// Register with:  claude mcp add transcriberr -- <path>/transcriberrcli mcp

private let mcpProtocolFallback = "2025-06-18"

func runMCPServer() -> Int32 {
    let server = MCPServer()
    return server.run()
}

final class MCPServer {
    /// Opened lazily at first tool call so `initialize` succeeds even if the
    /// store is missing — the error then surfaces per-call inside the MCP
    /// client, which is friendlier than dying on connect.
    private var kb: KBService?

    private func service() throws -> KBService {
        if let kb { return kb }
        let opened = try KBService.openReadOnly()
        kb = opened
        return opened
    }

    func run() -> Int32 {
        let stdin = FileHandle.standardInput
        var buffer = Data()
        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty { return 0 }   // EOF
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard !lineData.isEmpty else { continue }
                handleLine(lineData)
            }
        }
    }

    private func handleLine(_ data: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = message["method"] as? String else {
            // Parse error with no usable id — per JSON-RPC, id is null.
            send(["jsonrpc": "2.0", "id": NSNull(),
                  "error": ["code": -32700, "message": "Parse error"]])
            return
        }
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]

        // Notifications (no id) get no response.
        if id == nil {
            return
        }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? mcpProtocolFallback
            reply(id, result: [
                "protocolVersion": requested,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "transcriberr",
                               "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.3.0"],
            ])
        case "ping":
            reply(id, result: [:])
        case "tools/list":
            reply(id, result: ["tools": Self.toolDefinitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            reply(id, result: callTool(name, arguments))
        default:
            send(["jsonrpc": "2.0", "id": id ?? NSNull(),
                  "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    // MARK: - Tools

    /// Every tool returns markdown text content; failures use isError so the
    /// LLM sees an actionable message instead of a protocol fault.
    private func callTool(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        do {
            let kb = try service()
            let text: String
            switch name {
            case "kb_list":
                var since: Date?
                if let raw = arguments["since"] as? String {
                    since = KBService.parseSince(raw)
                    if since == nil {
                        return toolError("Cannot parse since '\(raw)'. Use ISO8601 or 7d/24h style.")
                    }
                }
                let rows = try kb.list(folder: arguments["folder"] as? String,
                                       tag: arguments["tag"] as? String,
                                       since: since,
                                       limit: intArg(arguments, "limit", 25))
                text = KBRender.markdownList(rows)

            case "kb_search":
                guard let query = arguments["query"] as? String, !query.isEmpty else {
                    return toolError("'query' is required.")
                }
                text = KBRender.markdown(
                    try kb.search(query, limit: intArg(arguments, "limit", 20)),
                    query: query)

            case "kb_get_transcript":
                guard let id = arguments["id"] as? String, !id.isEmpty else {
                    return toolError("'id' is required (from kb_list or kb_search).")
                }
                text = KBRender.markdown(try kb.transcript(
                    id: id,
                    startSeconds: doubleArg(arguments, "start_seconds"),
                    endSeconds: doubleArg(arguments, "end_seconds"),
                    offset: intArg(arguments, "offset", 0),
                    limit: intArg(arguments, "limit", 200)))

            case "kb_get_outputs":
                guard let id = arguments["id"] as? String, !id.isEmpty else {
                    return toolError("'id' is required (from kb_list or kb_search).")
                }
                text = KBRender.markdown(
                    try kb.outputs(id: id, presetId: arguments["preset"] as? String))

            case "kb_folders_tags":
                text = KBRender.markdown(folders: try kb.folders(), tags: try kb.tags())

            case "kb_stats":
                text = KBRender.markdown(try kb.stats())

            default:
                return toolError("Unknown tool: \(name)")
            }
            return ["content": [["type": "text", "text": text]]]
        } catch {
            return toolError(error.localizedDescription)
        }
    }

    private func toolError(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    private func intArg(_ args: [String: Any], _ key: String, _ def: Int) -> Int {
        (args[key] as? NSNumber)?.intValue ?? (args[key] as? String).flatMap(Int.init) ?? def
    }

    private func doubleArg(_ args: [String: Any], _ key: String) -> Double? {
        (args[key] as? NSNumber)?.doubleValue ?? (args[key] as? String).flatMap(Double.init)
    }

    // MARK: - Tool schemas

    static let toolDefinitions: [[String: Any]] = [
        [
            "name": "kb_list",
            "description": "List recordings in the Transcriberr knowledge base, newest first. "
                + "Each row shows the id prefix, title, date, duration, folder, tags, and which "
                + "generated outputs (summary/minutes/…) exist. Filter by folder, tag, or recency.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "folder": ["type": "string", "description": "Only recordings in this folder (case-insensitive name)."],
                    "tag": ["type": "string", "description": "Only recordings with this tag."],
                    "since": ["type": "string", "description": "ISO8601 timestamp or relative like '7d', '24h'."],
                    "limit": ["type": "integer", "description": "Max rows (default 25)."],
                ],
            ],
        ],
        [
            "name": "kb_search",
            "description": "Full-text search across all transcript segments and titles. Returns "
                + "per-recording hits with up to 5 matching timestamped lines each. Use the returned "
                + "id with kb_get_transcript or kb_get_outputs.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Text to find (case-insensitive)."],
                    "limit": ["type": "integer", "description": "Max recordings returned (default 20)."],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "kb_get_transcript",
            "description": "Read a recording's transcript with speaker names and timestamps. "
                + "Paginated (default 200 segments per call — the footer says how to fetch more) and "
                + "sliceable by time range. Ids are accepted as unique prefixes (≥4 chars). "
                + "Transcripts can be long: prefer kb_get_outputs (stored summaries) when a summary suffices.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Recording UUID or unique prefix from kb_list/kb_search."],
                    "start_seconds": ["type": "number", "description": "Only segments ending at/after this time."],
                    "end_seconds": ["type": "number", "description": "Only segments starting at/before this time."],
                    "offset": ["type": "integer", "description": "Segment offset for pagination (default 0)."],
                    "limit": ["type": "integer", "description": "Max segments (default 200)."],
                ],
                "required": ["id"],
            ],
        ],
        [
            "name": "kb_get_outputs",
            "description": "Read the stored LLM-generated documents for a recording: summary, "
                + "minutes, clean transcript, translation, context-rewrite. Much shorter than the raw "
                + "transcript — prefer this first.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Recording UUID or unique prefix."],
                    "preset": ["type": "string", "description": "Only this preset (e.g. 'summary', 'minutes')."],
                ],
                "required": ["id"],
            ],
        ],
        [
            "name": "kb_folders_tags",
            "description": "List all folders and tags with recording counts — the organization "
                + "vocabulary usable as kb_list filters.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "kb_stats",
            "description": "Knowledge-base overview: recording count, total audio duration, "
                + "languages, folders/tags/outputs counts, date range.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
    ]

    // MARK: - Transport

    private func reply(_ id: Any?, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func send(_ payload: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else {
            FileHandle.standardError.write(Data("mcp: response serialization failed\n".utf8))
            return
        }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}
