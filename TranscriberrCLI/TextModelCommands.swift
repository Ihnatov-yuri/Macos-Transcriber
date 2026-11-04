import Foundation

/// The text models the app can download (`ModelCatalog`).
///
///   transcriberrcli models                  each model, installed or not, and the picks
///   transcriberrcli models download <id>    download (or finish and verify) one
@MainActor
func cmdModels(_ args: [String]) async -> Int32 {
    if args.first == "download" {
        guard args.count > 1, let entry = ModelCatalog.entry(id: args[1]) else {
            print("[models] one of: \(ModelCatalog.entries.map(\.id).joined(separator: ", "))"); return 64
        }
        let downloader = ModelDownloader()
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if let p = downloader.progress[entry.id] {
                    print(String(format: "[models] %@ %.0f%%", p.status, p.fractionComplete * 100))
                }
            }
        }
        defer { ticker.cancel() }
        do {
            let dir = try await downloader.download(entry)
            print("[models] ✓ \(entry.name) at \(dir.path)")
            return 0
        } catch {
            print("[models] ❌ \(error.localizedDescription)"); return 1
        }
    }
    let general = ModelCatalog.selected(.general).id, superMerge = ModelCatalog.selected(.superMerge).id
    for e in ModelCatalog.entries {
        var picks: [String] = []
        if e.id == superMerge { picks.append("Super") }
        if e.id == general { picks.append("everything else") }
        print("\(e.id)\t\(e.runtime.rawValue)\t\(ModelCatalog.isInstalled(e) ? "installed" : "—")\t\(picks.joined(separator: ", "))")
    }
    return 0
}

/// Timing replay: logged app text calls (one JSON object per line: kind,
/// system, user, max_tokens) on a catalog model (default: the "everything
/// else" pick) through the app's own backend. One JSON line per call, in
/// the shape of llm-ab/bench_rt.py, so runtimes line up.
///
///   transcriberrcli textbench <calls.jsonl> [model-id]
@MainActor
func cmdTextBench(calls: String, modelID: String?) async -> Int32 {
    let entry = modelID.flatMap(ModelCatalog.entry(id:)) ?? ModelCatalog.selected(.general)
    guard ModelCatalog.isInstalled(entry) else {
        print("[textbench] \(entry.id) is not installed — transcriberrcli models download \(entry.id)"); return 1
    }
    guard let text = try? String(contentsOfFile: NSString(string: calls).expandingTildeInPath, encoding: .utf8) else {
        print("[textbench] cannot read \(calls)"); return 66
    }
    // The same path the app takes for this model; the saved choice comes back after.
    let key = ModelCatalog.Role.general.defaultsKey
    let saved = UserDefaults.standard.string(forKey: key)
    defer { UserDefaults.standard.set(saved, forKey: key) }
    UserDefaults.standard.set(entry.id, forKey: key)
    let factory = BackendFactory(prompts: PromptStore(), apiKeys: APIKeyStore())
    guard let backend = factory.backend(for: .localText) as? any LocalTextBackend else { return 1 }
    let t0 = Date()
    do { try await backend.load(modelPath: nil) } catch { print("[textbench] ❌ \(error)"); return 1 }
    FileHandle.standardError.write(Data("[textbench] loaded \(entry.name) in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s\n".utf8))
    for line in text.split(separator: "\n") {
        guard let call = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let kind = call["kind"] as? String, let system = call["system"] as? String,
              let user = call["user"] as? String, let maxTokens = call["max_tokens"] as? Int else { continue }
        let start = Date()
        let reply: String
        do {
            reply = try await backend.generateText(systemInstruction: system, userMessage: user, maxTokens: maxTokens)
        } catch {
            print("[textbench] ❌ \(kind): \(error)"); continue
        }
        let seconds = Date().timeIntervalSince(start)
        guard let s = await backend.lastStats else { continue }
        let record: [String: Any] = [
            "arm": entry.id, "kind": kind,
            "prompt_tokens": s.promptTokens, "completion_tokens": s.generatedTokens,
            "seconds": (seconds * 100).rounded() / 100,
            "decode_tps": (s.decodeTokensPerSecond * 10).rounded() / 10,
            "prefill_tps": s.prefillTokensPerSecond.rounded(),
            "peak_gb": (Double(peakFootprintBytes()) / 1e8).rounded() / 10,
            "reply": String(reply.prefix(160)),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]) {
            print(String(decoding: data, as: UTF8.self))
        }
    }
    return 0
}

/// The process's peak physical footprint so far (Activity Monitor's Memory,
/// at its highest), which counts GPU buffers on Apple silicon for both
/// runtimes.
private func peakFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? UInt64(info.ledger_phys_footprint_peak) : 0
}
