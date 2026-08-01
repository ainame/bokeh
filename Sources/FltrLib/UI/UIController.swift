import Foundation
import TUI

/// Immutable actor snapshot consumed by the detached frame builder.  The
/// `TextBuffer` reference is safe to read concurrently: it holds its read lock
/// for each text extraction (documented on `TextBuffer`).
private struct RenderSnapshot: Sendable {
    let state: UIState
    let visibleItems: [MatchedItem]
    let context: RenderContext
    let previewManager: PreviewManager?
    let previewContent: String
    let previewScrollOffset: Int
    let selectedItemName: String
}

private struct RenderedFrame: Sendable {
    let buffer: String
    let previewBounds: Bounds?
}

/// Pure, per-frame work deliberately kept off `UIController` so typing can
/// continue while visible-row highlighting and string assembly are in flight.
private enum FrameBuilder {
    static func build(
        snapshot: RenderSnapshot,
        renderer: UIRenderer,
        matcher: FuzzyMatcher,
        textBuffer: TextBuffer
    ) -> RenderedFrame? {
        var highlightResolver = HighlightResolver(matcher: matcher)
        var highlightPositions: [Item.Index: [UInt16]] = [:]
        highlightPositions.reserveCapacity(snapshot.visibleItems.count)
        let query = QueryNormalizer.normalizeForMatching(snapshot.state.query)

        for (index, matchedItem) in snapshot.visibleItems.enumerated() {
            guard !Task.isCancelled else { return nil }
            highlightPositions[matchedItem.item.index] = highlightResolver.positions(
                query: query,
                item: matchedItem.item,
                textBuffer: textBuffer
            )
            if index.isMultiple(of: 16), Task.isCancelled { return nil }
        }

        guard !Task.isCancelled else { return nil }
        var buffer = renderer.assembleFrame(
            state: snapshot.state,
            visibleItems: snapshot.visibleItems,
            highlightPositions: highlightPositions,
            context: snapshot.context,
            buffer: textBuffer
        )

        var previewBounds: Bounds?
        if snapshot.context.showSplitPreview, let manager = snapshot.previewManager {
            let startRow = 3
            let endRow = max(5, snapshot.context.rows) - 2
            let listWidth = snapshot.context.cols / 2 - 1
            let previewStartCol = listWidth + 2
            let previewWidth = snapshot.context.cols - listWidth - 1
            previewBounds = PreviewBounds(
                startRow: startRow,
                endRow: endRow,
                startCol: previewStartCol,
                endCol: snapshot.context.cols
            )
            buffer += manager.renderSplitPreview(
                content: snapshot.previewContent,
                scrollOffset: snapshot.previewScrollOffset,
                startRow: startRow,
                endRow: endRow,
                startCol: previewStartCol,
                width: previewWidth
            )
        } else if snapshot.context.showFloatingPreview, let manager = snapshot.previewManager {
            let floating = manager.renderFloatingPreview(
                content: snapshot.previewContent,
                scrollOffset: snapshot.previewScrollOffset,
                itemName: snapshot.selectedItemName,
                rows: snapshot.context.rows,
                cols: snapshot.context.cols
            )
            previewBounds = floating.bounds
            buffer += floating.buffer
        }

        return RenderedFrame(buffer: buffer, previewBounds: previewBounds)
    }
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

    // Cancellable background tasks
    private var currentMatchTask: Task<Void, Never>?
    private var currentPreviewTask: Task<Void, Never>?
    private var fetchItemsTask: Task<Void, Never>?
    private var matchGeneration: UInt = 0
    private var currentFrameTask: Task<RenderedFrame?, Never>?
    private var pendingResultRenderTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var renderGeneration: UInt = 0

    private var renderScheduled = false
    private var needsFullRender = false

    private var mergerCache = MergerCache()

    // Per-chunk result cache shared across TaskGroup partitions; internally locked.
    private let chunkCache = ChunkCache()

    // Set to true the moment the exit decision is made.  Guards render() and
    // applyMatchResults() so that in-flight detached tasks cannot spill ANSI
    // escape sequences onto stdout after ttyFd has been closed.
    private var isExiting = false

    init(terminal: any Terminal, matcher: FuzzyMatcher, cache: ItemCache, reader: StdinReader, maxHeight: Int? = nil, multiSelect: Bool = false, previewCommand: String? = nil, useFloatingPreview: Bool = false, debounceDelay: Duration = .zero) {
        self.terminal = terminal
        self.matcher = matcher
        self.engine = MatchingEngine(matcher: matcher)
        self.cache = cache
        self.textBuffer = cache.buffer
        self.reader = reader
        self.maxHeight = maxHeight
        self.multiSelect = multiSelect
        // Kept for source compatibility with callers from the debounce-based
        // implementation. Search dispatch is now immediate and latest-wins.
        _ = debounceDelay

        self.preview = PreviewState(command: previewCommand, useFloating: useFloatingPreview)
        self.renderer = UIRenderer(maxHeight: maxHeight, multiSelect: multiSelect)
        self.inputHandler = InputHandler(
            multiSelect: multiSelect,
            hasPreview: previewCommand != nil
        )
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

        // Input is a continuous producer, not something the UI loop polls.
        // Install its reducer before the first prompt is published: terminal
        // output is asynchronous, so a user may type as soon as it appears.
        let inputEvents = await terminal.inputEvents()
        inputTask = Task { [weak self] in
            for await key in inputEvents {
                guard !Task.isCancelled else { return }
                await self?.handleKey(key: key)
            }
        }

        refreshPreview()
        await render(generation: renderGeneration)

        var lastRefresh = Date()
        let refreshIntervalFast: TimeInterval = 0.02
        let refreshIntervalSlow: TimeInterval = 0.1

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
                    fetchItemsTask = Task {
                        let query = self.state.query
                        let generation = self.matchGeneration
                        let chunkList = await self.cache.snapshotChunkList()

                        self.invalidateMergerCache()
                        self.chunkCache.clear()

                        await self.runMatch(
                            query: query,
                            generation: generation,
                            previousQuery: "",  // force full search
                            merger: .empty,
                            chunkList: chunkList
                        )
                    }

                    lastRefresh = now
                }
            }

            // Stdin maintenance has its own cadence. It never gates input.
            try? await Task.sleep(for: .milliseconds(5))
        }

        // Freeze state and suppress any in-flight renders before we tear down
        // the terminal.  Without this, a detached match task that races past
        // its cancellation checkpoint can call render() while UIController is
        // suspended on exitRawMode(), enqueue a write on RawTerminal after
        // ttyFd is closed, and spill the entire UI frame onto stdout.
        isExiting = true

        currentMatchTask?.cancel()
        currentPreviewTask?.cancel()
        fetchItemsTask?.cancel()
        currentFrameTask?.cancel()
        pendingResultRenderTask?.cancel()
        inputTask?.cancel()
        if let inputTask {
            await inputTask.value
        }
        inputTask = nil
        await terminal.exitRawMode()

        return state.getSelectedItems()
    }

    private func handleKey(key: Key) async {
        let (rows, cols) = (try? await terminal.getSize()) ?? (24, 80)
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
            if !state.shouldExit {
                if key == .tab {
                    scheduleRender()
                } else {
                    await renderPrompt(cols: cols)
                }
            }

        case .scheduleMatchUpdate:
            scheduleMatchUpdate()
            await renderPrompt(cols: cols)

        case .updatePreview:
            refreshPreview()
            scheduleRender()

        case .updatePreviewScroll(let offset):
            preview.scrollOffset = offset
            scheduleRender()

        case .togglePreview:
            if preview.useFloating {
                preview.showFloating.toggle()
                if preview.showFloating { refreshPreview() }
            } else {
                preview.showSplit.toggle()
                if preview.showSplit { refreshPreview() }
            }
            scheduleRender()
        }
    }

    private func scheduleMatchUpdate() {
        matchGeneration &+= 1
        currentMatchTask?.cancel()
        fetchItemsTask?.cancel()

        // Snapshot the actor-owned incremental state synchronously, then do
        // the potentially suspending cache snapshot and CPU work elsewhere.
        let query = state.query
        let previousQuery = state.previousQuery
        let merger = state.merger
        let generation = matchGeneration
        let cache = self.cache
        currentMatchTask = Task.detached(priority: .userInitiated) {
            let chunkList = await cache.snapshotChunkList()
            guard !Task.isCancelled else { return }
            await self.runMatch(
                query: query,
                generation: generation,
                previousQuery: previousQuery,
                merger: merger,
                chunkList: chunkList
            )
        }
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
            self.scheduleRender()
        }
    }

    /// Apply only the newest requested result. This is separate from task
    /// cancellation because cancellation is cooperative.
    private func applyMatchResults(_ results: ResultMerger, query: String, generation: UInt) -> Bool {
        guard !isExiting, generation == matchGeneration else { return false }
        state.updateMatches(results)
        state.previousQuery = QueryNormalizer.normalizeForMatching(query)
        return true
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
        needsFullRender = true
        renderGeneration &+= 1
        currentFrameTask?.cancel()
        guard !renderScheduled else { return }
        renderScheduled = true

        Task {
            while needsFullRender {
                needsFullRender = false
                await render(generation: renderGeneration)
            }
            renderScheduled = false
        }
    }

    /// Coalesce list refreshes caused by fast successive search completions.
    /// Prompt updates are rendered immediately; the expensive full frame is
    /// produced only after typing has paused for one short frame interval.
    private func scheduleResultRender() {
        pendingResultRenderTask?.cancel()
        pendingResultRenderTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            pendingResultRenderTask = nil
            scheduleRender()
        }
    }

    /// Repaint only the prompt while a new search is running. This executes in
    /// the current key action, avoiding an extra task-scheduling and terminal-
    /// size round trip on the typing path.
    private func renderPrompt(cols: Int) async {
        renderGeneration &+= 1
        currentFrameTask?.cancel()
        pendingResultRenderTask?.cancel()
        guard !isExiting else { return }
        let prompt = renderer.renderInputLine(
            query: state.query,
            cursorPosition: state.cursorPosition,
            cols: max(10, cols)
        )
        terminal.write(prompt)
    }

    // MARK: - Matching

    /// Core match loop: determine whether to use the incremental or full-search
    /// path, consult / populate the merger cache, then apply results and render.
    /// Called from detached tasks; everything that touches actor state goes
    /// through `await self.*` helper calls.
    nonisolated private func runMatch(
        query: String,
        generation: UInt,
        previousQuery: String,
        merger: ResultMerger,
        chunkList: ChunkList
    ) async {
        guard !Task.isCancelled else { return }
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
            guard !Task.isCancelled,
                  await applyMatchResults(cached, query: normalizedQuery, generation: generation)
            else { return }
            await refreshPreviewIfNeeded(results: cached)
            await scheduleResultRender()
            return
        }

        let matchStart = Date()
        let results: ResultMerger
        if canUseIncremental {
            results = await engine.matchItemsParallel(pattern: normalizedQuery, items: merger.allItems(), buffer: textBuffer)
        } else {
            results = await engine.matchChunksParallel(pattern: normalizedQuery, chunkList: chunkList, cache: chunkCache, buffer: textBuffer)
        }

        guard !Task.isCancelled else { return }

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

        guard await applyMatchResults(results, query: normalizedQuery, generation: generation) else { return }
        await refreshPreviewIfNeeded(results: results)
        await scheduleResultRender()
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

    private func render(generation: UInt) async {
        guard !isExiting else { return }
        let rawSize = (try? await terminal.getSize()) ?? (24, 80)
        let rows = max(5, rawSize.0)
        let cols = max(10, rawSize.1)

        // Layout: input | border | items… | status  →  4 rows of chrome
        let availableRows = rows - 4
        let displayHeight = maxHeight.map { min($0, availableRows) } ?? availableRows

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
        let textBuffer = self.textBuffer
        let selectedItemName = preview.showFloating
            ? state.merger.get(state.selectedIndex).map { $0.item.text(in: textBuffer) } ?? ""
            : ""
        let snapshot = RenderSnapshot(
            state: state,
            visibleItems: visibleItems,
            context: context,
            previewManager: preview.manager,
            previewContent: preview.cachedPreview,
            previewScrollOffset: preview.scrollOffset,
            selectedItemName: selectedItemName
        )
        let renderer = self.renderer
        let matcher = self.matcher
        let frameTask = Task.detached(priority: .userInitiated) {
            FrameBuilder.build(
                snapshot: snapshot,
                renderer: renderer,
                matcher: matcher,
                textBuffer: textBuffer
            )
        }
        currentFrameTask = frameTask
        guard let frame = await frameTask.value,
              !isExiting,
              generation == renderGeneration
        else { return }

        preview.bounds = frame.previewBounds
        terminal.write(frame.buffer)
        terminal.flush()
    }
}
