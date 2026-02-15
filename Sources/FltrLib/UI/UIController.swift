import Foundation
import TUI
import AsyncAlgorithms

/// Single-field message yielded into the debounced query stream.
/// previousQuery is intentionally absent — it is read fresh from the actor
/// at the point of consumption to avoid staleness.
struct QueryUpdate: Sendable {
    let query: String
}

/// Main UI controller - event loop and rendering
actor UIController {
    private let terminal: any Terminal
    private let matcher: FuzzyMatcher
    private let engine: MatchingEngine
    private let cache: ItemCache
    private let textBuffer: TextBuffer  // captured once; ItemCache.buffer is a let
    private let reader: StdinReader
    private var state = UIState()
    private var maxHeight: Int?  // nil = use full terminal height
    private var lastItemCount: Int = 0
    private var isReadingStdin: Bool = true  // Cache to avoid async call in render
    private var spinnerFrame: Int = 0  // Spinner animation frame counter
    private let multiSelect: Bool
    private var preview: PreviewState
    private let renderer: UIRenderer
    private let inputHandler: InputHandler

    // Debounced query stream feeds runMatch; the continuation is the write end.
    private let debounceDelay: Duration
    private let queryUpdateStream: AsyncStream<QueryUpdate>
    private let queryUpdateContinuation: AsyncStream<QueryUpdate>.Continuation

    // Cancellable background tasks
    private var currentMatchTask: Task<Void, Never>?
    private var currentPreviewTask: Task<Void, Never>?
    private var fetchItemsTask: Task<Void, Never>?

    private var renderScheduled = false  // coalesces concurrent render requests

    private var mergerCache = MergerCache()
    private var highlightResolver: HighlightResolver

    // Per-chunk result cache shared across TaskGroup partitions; internally locked.
    private let chunkCache = ChunkCache()

    // Set to true the moment the exit decision is made.  Guards render() and
    // applyMatchResults() so that in-flight detached tasks cannot spill ANSI
    // escape sequences onto stdout after ttyFd has been closed.
    private var isExiting = false

    init(terminal: any Terminal, matcher: FuzzyMatcher, cache: ItemCache, reader: StdinReader, maxHeight: Int? = nil, multiSelect: Bool = false, previewCommand: String? = nil, useFloatingPreview: Bool = false, debounceDelay: Duration = .milliseconds(50)) {
        self.terminal = terminal
        self.matcher = matcher
        self.engine = MatchingEngine(matcher: matcher)
        self.cache = cache
        self.textBuffer = cache.buffer
        self.reader = reader
        self.maxHeight = maxHeight
        self.multiSelect = multiSelect
        self.debounceDelay = debounceDelay

        self.preview = PreviewState(command: previewCommand, useFloating: useFloatingPreview)
        self.renderer = UIRenderer(maxHeight: maxHeight, multiSelect: multiSelect)
        self.highlightResolver = HighlightResolver(matcher: matcher)
        self.inputHandler = InputHandler(
            multiSelect: multiSelect,
            hasPreview: previewCommand != nil
        )

        var continuation: AsyncStream<QueryUpdate>.Continuation!
        let stream = AsyncStream<QueryUpdate> { continuation = $0 }
        self.queryUpdateStream = stream
        self.queryUpdateContinuation = continuation
    }

    /// Run the main UI loop
    func run() async throws -> [Item] {
        try await terminal.enterRawMode()

        // Initial snapshot — may be empty if stdin is still streaming.
        let initialChunkList = await cache.snapshotChunkList()
        lastItemCount = initialChunkList.count
        state.totalItems = initialChunkList.count
        let initialMatches = await engine.matchChunksParallel(pattern: "", chunkList: initialChunkList, cache: chunkCache, buffer: textBuffer)
        state.updateMatches(initialMatches)

        refreshPreview()
        await render()

        var lastRefresh = Date()
        let refreshIntervalFast: TimeInterval = 0.02
        let refreshIntervalSlow: TimeInterval = 0.1

        // Debounced matching runs OUTSIDE the actor so it never blocks input.
        // Each iteration waits for the previous match to finish (so that
        // state.merger is up-to-date for incremental filtering), then fires
        // a new detached task that does the heavy work.
        let debounceTask = Task {
            for await update in queryUpdateStream.debounce(for: debounceDelay) {
                if let prevTask = currentMatchTask {
                    _ = await prevTask.value
                }

                // Snapshot actor state while we still have isolation.
                let previousQuery  = self.state.previousQuery
                let currentMerger  = self.state.merger
                let chunkList      = await self.cache.snapshotChunkList()
                self.updatePreviousQuery(update.query)

                currentMatchTask = Task.detached {
                    await self.runMatch(
                        query: update.query,
                        previousQuery: previousQuery,
                        merger: currentMerger,
                        chunkList: chunkList
                    )
                }
            }
        }

        // Main event loop
        while !state.shouldExit {
            // Exit if the controlling terminal has disconnected (e.g. shell closed the
            // subshell, or the terminal emulator was closed).  Without this check fltr
            // would loop forever burning CPU and memory.
            if await terminal.ttyBroken {
                break
            }

            let wasReadingStdin = isReadingStdin
            isReadingStdin = await !reader.readingComplete()

            // Trigger render when stdin completes to hide spinner immediately
            if wasReadingStdin && !isReadingStdin {
                scheduleRender()
            }

            if let key = await terminal.readInputEvent() {
                await handleKey(key: key)
                scheduleRender()
            } else {
                let currentCount = await cache.count()

                if currentCount > lastItemCount {
                    let now = Date()
                    // Keep perceived latency low for small/medium streams while
                    // retaining conservative throttling for very large feeds.
                    let refreshInterval = currentCount < 10_000 ? refreshIntervalFast : refreshIntervalSlow
                    if now.timeIntervalSince(lastRefresh) >= refreshInterval {
                        lastItemCount = currentCount
                        state.totalItems = currentCount

                        fetchItemsTask?.cancel()
                        currentMatchTask?.cancel()

                        // Re-match against the fresh item set in the background.
                        // Always a full search: previousQuery is owned by the
                        // debounce task; writing it here would let the debounce
                        // path see a stale value and permanently cap its results.
                        fetchItemsTask = Task {
                            let chunkList = await self.cache.snapshotChunkList()
                            let query     = self.state.query

                            self.invalidateMergerCache()
                            self.chunkCache.clear()

                            await self.runMatch(
                                query: query,
                                previousQuery: "",  // force full search
                                merger: .empty,
                                chunkList: chunkList
                            )
                        }

                        lastRefresh = now
                    }
                }

                // Brief sleep to reduce CPU usage when no input available
                // Terminal readByte already has 100ms timeout, so combined we check
                // for updates approximately every 105ms when idle
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        // Freeze state and suppress any in-flight renders before we tear down
        // the terminal.  Without this, a detached match task that races past
        // its cancellation checkpoint can call render() while UIController is
        // suspended on exitRawMode(), enqueue a write on RawTerminal after
        // ttyFd is closed, and spill the entire UI frame onto stdout.
        isExiting = true

        queryUpdateContinuation.finish()
        currentMatchTask?.cancel()
        currentPreviewTask?.cancel()
        fetchItemsTask?.cancel()
        debounceTask.cancel()

        await terminal.exitRawMode()

        return state.getSelectedItems()
    }

    private func handleKey(key: Key) async {
        let (rows, _) = (try? await terminal.getSize()) ?? (24, 80)
        let availableRows = rows - 4  // input + border + status + spacing
        let visibleHeight = maxHeight.map { min($0, availableRows) } ?? availableRows

        let context = InputContext(
            visibleHeight: visibleHeight,
            cachedPreview: preview.cachedPreview,
            previewScrollOffset: preview.scrollOffset,
            previewBounds: preview.bounds
        )

        // Handle key event
        let action = inputHandler.handleKeyEvent(key: key, state: &state, context: context)

        switch action {
        case .none:
            break

        case .scheduleMatchUpdate:
            scheduleMatchUpdate()

        case .updatePreview:
            refreshPreview()

        case .updatePreviewScroll(let offset):
            preview.scrollOffset = offset

        case .togglePreview:
            if preview.useFloating {
                preview.showFloating.toggle()
                if preview.showFloating { refreshPreview() }
            } else {
                preview.showSplit.toggle()
                if preview.showSplit { refreshPreview() }
            }
        }
    }

    private func scheduleMatchUpdate() {
        let update = QueryUpdate(query: state.query)
        queryUpdateContinuation.yield(update)
    }

    /// Cancel any in-flight preview and kick off a fresh one in the background.
    /// Every call site that needs a new preview reduces to this single path.
    /// No-ops when the preview pane is hidden — avoids a subprocess round-trip
    /// before the user has opted in via Ctrl-O.
    private func refreshPreview() {
        guard preview.showSplit || preview.showFloating else { return }
        guard let manager = preview.manager, let command = preview.command else { return }
        currentPreviewTask?.cancel()
        currentPreviewTask = Task {
            await self.updatePreviewAsync(manager: manager, command: command)
            await self.render()
        }
    }

    private func updatePreviousQuery(_ query: String) {
        state.previousQuery = QueryNormalizer.normalizeForMatching(query)
    }

    private func applyMatchResults(_ results: ResultMerger) {
        guard !isExiting else { return }
        state.updateMatches(results)
    }

    private func updatePreviewAsync(manager: PreviewManager, command: String) async {
        guard let selectedItem = state.merger.get(state.selectedIndex) else {
            preview.cachedPreview = ""
            preview.scrollOffset = 0
            return
        }

        let newPreview = await manager.executeCommand(command, item: selectedItem.item.text(in: textBuffer))
        preview.setCached(newPreview)
    }

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true

        Task {
            await render()
            renderScheduled = false
        }
    }

    // MARK: - Matching

    /// Core match loop: determine whether to use the incremental or full-search
    /// path, consult / populate the merger cache, then apply results and render.
    /// Called from detached tasks; everything that touches actor state goes
    /// through `await self.*` helper calls.
    nonisolated private func runMatch(
        query: String,
        previousQuery: String,
        merger: ResultMerger,
        chunkList: ChunkList
    ) async {
        let overallStart = Date()
        let normalizedQuery = QueryNormalizer.normalizeForMatching(query)
        let normalizedPreviousQuery = QueryNormalizer.normalizeForMatching(previousQuery)

        // Incremental filtering: when the new query extends the previous one
        // the previous match set is a strict superset, so narrowing is lossless.
        let canUseIncremental = !normalizedPreviousQuery.isEmpty &&
                                normalizedQuery.hasPrefix(normalizedPreviousQuery) &&
                                normalizedQuery.count > normalizedPreviousQuery.count

        // Merger cache hit — only valid on the full-search path (the
        // incremental candidate set is a subset and would differ).
        if !canUseIncremental, let cached = await lookupMergerCache(pattern: normalizedQuery, itemCount: chunkList.count) {
            await applyMatchResults(cached)
            await refreshPreviewIfNeeded(results: cached)
            await render()
            return
        }

        let matchStart = Date()
        let results: ResultMerger
        if canUseIncremental {
            results = await engine.matchItemsParallel(pattern: normalizedQuery, items: merger.allItems(), buffer: textBuffer)
        } else {
            results = await engine.matchChunksParallel(pattern: normalizedQuery, chunkList: chunkList, cache: chunkCache, buffer: textBuffer)
        }

        logMatchTime(
            query: normalizedQuery,
            matchTime: Date().timeIntervalSince(matchStart) * 1000,
            totalTime: Date().timeIntervalSince(overallStart) * 1000,
            itemCount: chunkList.count,
            resultCount: results.count
        )

        if !canUseIncremental {
            await storeMergerCache(pattern: normalizedQuery, itemCount: chunkList.count, results: results)
        }

        await applyMatchResults(results)
        await refreshPreviewIfNeeded(results: results)
        await render()
    }

    /// Update the cached preview when there are results to show.
    nonisolated private func refreshPreviewIfNeeded(results: ResultMerger) async {
        guard results.count > 0 else { return }
        await refreshPreviewIfConfigured()
    }

    /// Actor-isolated gate: only calls updatePreviewAsync when preview is visible and configured.
    private func refreshPreviewIfConfigured() async {
        guard preview.showSplit || preview.showFloating else { return }
        guard let manager = preview.manager, let command = preview.command else { return }
        await updatePreviewAsync(manager: manager, command: command)
    }

    /// Append a single perf-log line when a match round takes > 10 ms.
    private nonisolated func logMatchTime(query: String, matchTime: Double, totalTime: Double, itemCount: Int, resultCount: Int) {
        guard matchTime > 10 else { return }
        let msg = "[\(query)] match: \(String(format: "%.1f", matchTime))ms (\(itemCount) items → \(resultCount) results), total: \(String(format: "%.1f", totalTime))ms\n"
        let path = URL(fileURLWithPath: "/tmp/fltr-perf.log")
        if let handle = try? FileHandle(forWritingTo: path) {
            handle.seekToEndOfFile()
            handle.write(msg.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? msg.data(using: .utf8)?.write(to: path)
        }
    }

    // MARK: - Merger cache (actor-isolated forwarding — keeps nonisolated
    //          call sites in runMatch unchanged)

    private func lookupMergerCache(pattern: String, itemCount: Int) -> ResultMerger? {
        mergerCache.lookup(pattern: pattern, itemCount: itemCount)
    }

    private func storeMergerCache(pattern: String, itemCount: Int, results: ResultMerger) {
        mergerCache.store(pattern: pattern, itemCount: itemCount, results: results)
    }

    private func invalidateMergerCache() {
        mergerCache.invalidate()
    }

    private func render() async {
        guard !isExiting else { return }
        let rawSize = (try? await terminal.getSize()) ?? (24, 80)
        let rows = max(5, rawSize.0)
        let cols = max(10, rawSize.1)

        // Layout: input | border | items… | status  →  4 rows of chrome
        let availableRows = rows - 4
        let displayHeight = maxHeight.map { min($0, availableRows) } ?? availableRows

        let previewWidth: Int
        let previewStartCol: Int
        if preview.showSplit {
            let listWidth = cols / 2 - 1
            previewWidth = cols - listWidth - 1
            previewStartCol = listWidth + 2
        } else {
            previewWidth = 0
            previewStartCol = 0
        }

        let context = RenderContext(
            rows: rows,
            cols: cols,
            isReadingStdin: isReadingStdin,
            showSplitPreview: preview.showSplit,
            showFloatingPreview: preview.showFloating,
            spinnerFrame: spinnerFrame
        )

        // Increment spinner frame for animation
        if isReadingStdin {
            spinnerFrame = (spinnerFrame + 1) % 10
        }

        // Materialise the visible window here; assembleFrame receives state
        // by value and cannot call mutating Merger methods itself.
        let visibleItems = state.merger.slice(state.scrollOffset, state.scrollOffset + displayHeight)
        var highlightPositions: [Item.Index: [UInt16]] = [:]
        highlightPositions.reserveCapacity(visibleItems.count)
        for matchedItem in visibleItems {
            highlightPositions[matchedItem.item.index] = highlightResolver.positions(
                query: QueryNormalizer.normalizeForMatching(state.query),
                item: matchedItem.item,
                textBuffer: textBuffer
            )
        }

        var buffer = renderer.assembleFrame(
            state: state,
            visibleItems: visibleItems,
            highlightPositions: highlightPositions,
            context: context,
            buffer: textBuffer
        )

        if preview.showSplit {
            let startRow = 3
            let endRow = displayHeight + 2
            buffer += preview.renderSplit(startRow: startRow, endRow: endRow, startCol: previewStartCol, width: previewWidth, cols: cols)
        } else if preview.showFloating {
            let itemName = state.merger.get(state.selectedIndex).map { $0.item.text(in: textBuffer) } ?? ""
            buffer += preview.renderFloating(rows: rows, cols: cols, itemName: itemName)
        } else {
            preview.bounds = nil
        }

        await terminal.write(buffer)
        await terminal.flush()
    }
}
