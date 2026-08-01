import Synchronization

/// A cheap, sendable progress counter shared by the partitions of one search.
///
/// The counter deliberately does not notify observers. Workers only take its
/// lock after a completed batch or chunk, and the UI samples it at its existing
/// refresh cadence. That keeps progress reporting out of the input path.
final class SearchProgress: Sendable {
    struct Snapshot: Sendable {
        let completed: Int
        let total: Int
    }

    private struct State: Sendable {
        var completed: Int = 0
        var total: Int
    }

    private let state: Mutex<State>

    init(total: Int) {
        state = Mutex(State(total: max(0, total)))
    }

    func advance(by count: Int) {
        guard count > 0 else { return }
        state.withLock { state in
            state.completed = min(state.total, state.completed + count)
        }
    }

    func setTotal(_ total: Int) {
        state.withLock { state in
            state.total = max(0, total)
            state.completed = min(state.completed, state.total)
        }
    }

    func snapshot() -> Snapshot {
        state.withLock { state in
            Snapshot(completed: state.completed, total: state.total)
        }
    }
}
