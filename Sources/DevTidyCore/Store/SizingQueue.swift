import Foundation

/// Bounded work queue (default 4-wide) for lazy size measurements. Jobs are queued as reports arrive, so the
/// builds-scan stream is drained at full speed while at most `limit` measurements run at once.
@MainActor
final class SizingQueue {
    typealias Job = @MainActor () async -> Void

    let limit: Int
    private var pending: [Job] = []
    private var running: [Int: Task<Void, Never>] = [:]
    private var nextID = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var cancelled = false

    init(limit: Int = 4) {
        self.limit = max(1, limit)
    }

    func enqueue(_ job: @escaping Job) {
        guard !cancelled else { return }
        pending.append(job)
        pump()
    }

    /// Returns once nothing is queued or running (also after `cancelAll()`, when the cancelled jobs have wound down).
    func waitUntilIdle() async {
        if isIdle { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func cancelAll() {
        cancelled = true
        pending.removeAll()
        for task in running.values { task.cancel() }
        resumeWaitersIfIdle()
    }

    private var isIdle: Bool { running.isEmpty && pending.isEmpty }

    private func pump() {
        while running.count < limit, !pending.isEmpty {
            let job = pending.removeFirst()
            let id = nextID
            nextID += 1
            running[id] = Task { [weak self] in
                await job()
                self?.finished(id)
            }
        }
        resumeWaitersIfIdle()
    }

    private func finished(_ id: Int) {
        running[id] = nil
        pump()
    }

    private func resumeWaitersIfIdle() {
        guard isIdle, !waiters.isEmpty else { return }
        let toResume = waiters
        waiters = []
        for waiter in toResume { waiter.resume() }
    }
}
