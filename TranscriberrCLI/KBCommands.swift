import Foundation

// `transcriberrcli kb …` — structured read-only access to the transcript
// knowledge base. Markdown by default (human/LLM-readable), `--json` for the
// stable DTO envelope. Exit codes: 0 ok, 1 failure, 64 usage.

func kbUsage() {
    print("""
    transcriberrcli kb — query the Transcriberr knowledge base (read-only)

    USAGE
      transcriberrcli kb list    [--folder NAME] [--tag NAME] [--since ISO8601|7d|24h] [--limit N] [--json]
      transcriberrcli kb search  <query> [--limit N] [--json]
      transcriberrcli kb get     <id|prefix> [--format json|md|txt] [--from SECS] [--to SECS] [--offset N] [--limit N]
      transcriberrcli kb outputs <id|prefix> [--preset ID] [--json]
      transcriberrcli kb folders [--json]
      transcriberrcli kb tags    [--json]
      transcriberrcli kb stats   [--json]

    GLOBAL
      --store PATH   read a specific .store file (default:
                     ~/Library/Application Support/Transcriberr.store,
                     also overridable via TRANSCRIBERR_STORE)

    Recording ids accepted as full UUIDs or unique prefixes (≥4 chars).
    The database is opened read-only; safe while Transcriberr.app is running.
    """)
}

/// Tiny flag scanner: positionals + `--key value` / bare `--flag`.
struct KBArgs {
    var positionals: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String]) {
        var i = 0
        let valueOptions: Set<String> = ["store", "folder", "tag", "since", "limit",
                                         "format", "from", "to", "offset", "preset"]
        while i < raw.count {
            let arg = raw[i]
            if arg.hasPrefix("--") {
                let key = String(arg.dropFirst(2))
                if valueOptions.contains(key), i + 1 < raw.count {
                    options[key] = raw[i + 1]
                    i += 2
                    continue
                }
                flags.insert(key)
            } else {
                positionals.append(arg)
            }
            i += 1
        }
    }

    var json: Bool { flags.contains("json") }
    func int(_ key: String, default def: Int) -> Int {
        options[key].flatMap(Int.init) ?? def
    }
    func double(_ key: String) -> Double? {
        options[key].flatMap(Double.init)
    }
}

private func fail(_ message: String) -> Int32 {
    FileHandle.standardError.write(Data("kb: \(message)\n".utf8))
    return 1
}

func cmdKB(_ raw: [String]) -> Int32 {
    let parsed = KBArgs(raw)
    guard let sub = parsed.positionals.first else { kbUsage(); return 64 }
    let rest = Array(parsed.positionals.dropFirst())

    let kb: KBService
    do {
        let url = parsed.options["store"].map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        }
        kb = try KBService.openReadOnly(at: url)
    } catch {
        return fail(error.localizedDescription)
    }

    do {
        switch sub {
        case "list":
            var since: Date?
            if let raw = parsed.options["since"] {
                guard let parsedDate = KBService.parseSince(raw) else {
                    return fail("cannot parse --since '\(raw)' (use ISO8601, or 7d/24h style)")
                }
                since = parsedDate
            }
            let rows = try kb.list(folder: parsed.options["folder"],
                                   tag: parsed.options["tag"],
                                   since: since,
                                   limit: parsed.int("limit", default: 25))
            print(parsed.json ? try KBJSON.envelope("recordings", rows)
                              : KBRender.markdownList(rows))

        case "search":
            guard let query = rest.first else { kbUsage(); return 64 }
            let hits = try kb.search(query, limit: parsed.int("limit", default: 20))
            print(parsed.json ? try KBJSON.envelope("hits", hits)
                              : KBRender.markdown(hits, query: query))

        case "get":
            guard let id = rest.first else { kbUsage(); return 64 }
            let t = try kb.transcript(id: id,
                                      startSeconds: parsed.double("from"),
                                      endSeconds: parsed.double("to"),
                                      offset: parsed.int("offset", default: 0),
                                      limit: parsed.int("limit", default: 200))
            switch parsed.options["format"] ?? "md" {
            case "json": print(try KBJSON.envelope("transcript", t))
            case "txt":  print(KBRender.plainText(t))
            case "md":   print(KBRender.markdown(t))
            default:     return fail("unknown --format (use json|md|txt)")
            }

        case "outputs":
            guard let id = rest.first else { kbUsage(); return 64 }
            let docs = try kb.outputs(id: id, presetId: parsed.options["preset"])
            print(parsed.json ? try KBJSON.envelope("outputs", docs)
                              : KBRender.markdown(docs))

        case "folders":
            let folders = try kb.folders()
            print(parsed.json ? try KBJSON.envelope("folders", folders)
                              : KBRender.markdown(folders: folders, tags: []))

        case "tags":
            let tags = try kb.tags()
            print(parsed.json ? try KBJSON.envelope("tags", tags)
                              : KBRender.markdown(folders: [], tags: tags))

        case "stats":
            let stats = try kb.stats()
            print(parsed.json ? try KBJSON.envelope("stats", stats)
                              : KBRender.markdown(stats))

        case "help", "-h", "--help":
            kbUsage()

        default:
            kbUsage()
            return 64
        }
    } catch {
        return fail(error.localizedDescription)
    }
    return 0
}
