import Foundation

/// Tracks which recordings currently have background audio post-processing
/// (echo-cancel mix rebuild, AAC compression) in flight, so a reader that
/// needs a recording's files to be stable — namely `RecordingRepository.merge`
/// — can wait for that work to quiesce instead of racing it. Deferring
/// post-processing off `RecordModel.endRecording`'s critical path (so Stop
/// doesn't block on it) reopened a window that used to be closed by
/// compression always finishing before a recording was even saved/visible;
/// this closes it back up without reintroducing the block.
actor AudioPostProcessTracker {
    private var busy: Set<UUID> = []
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    func markBusy(_ id: UUID) {
        busy.insert(id)
    }

    func markIdle(_ id: UUID) {
        busy.remove(id)
        let pending = waiters.removeValue(forKey: id) ?? []
        for cont in pending { cont.resume() }
    }

    func waitUntilIdle(_ id: UUID) async {
        guard busy.contains(id) else { return }
        await withCheckedContinuation { cont in
            waiters[id, default: []].append(cont)
        }
    }
}
