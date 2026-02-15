import Foundation
import TUI

public struct Options {
    public let height: Int?
    public let multi: Bool
    public let caseSensitive: Bool
    public let preview: String?
    public let previewFloat: String?
    public let scheme: SortScheme

    public init(height: Int?, multi: Bool, caseSensitive: Bool, preview: String?, previewFloat: String?, scheme: SortScheme = .path) {
        self.height = height
        self.multi = multi
        self.caseSensitive = caseSensitive
        self.preview = preview
        self.previewFloat = previewFloat
        self.scheme = scheme
    }
}

public struct Runner {
    public let options: Options

    public init(options: Options) {
        self.options = options
    }

    /// Non-interactive query mode: read all stdin, run the same matchChunksParallel
    /// path the interactive UI uses, and dump top results with rank points to stdout.
    public func runQuery(_ query: String) async throws {
        let normalizedQuery = QueryNormalizer.normalizeForMatching(query)

        let cache = ItemCache()
        let reader = StdinReader(cache: cache)
        let readTask = await reader.startReading()

        // Wait for stdin to finish — no timeout, we need the full dataset
        await readTask.value

        let matcher = FuzzyMatcher(caseSensitive: options.caseSensitive, scheme: options.scheme)
        let engine = MatchingEngine(matcher: matcher)
        let chunkList = await cache.snapshotChunkList()
        let chunkCache = ChunkCache()

        let buf = cache.buffer
        var merger = await engine.matchChunksParallel(pattern: normalizedQuery, chunkList: chunkList, cache: chunkCache, buffer: buf)
        let prepared = matcher.prepare(normalizedQuery)
        var scratch = matcher.makeBuffer()

        let totalItems = await cache.count()
        print("[query='\(query)' normalized='\(normalizedQuery)' scheme=\(options.scheme) matcher=fuzzymatch results=\(merger.count)/\(totalItems)]")
        print("")
        let top = merger.slice(0, 30)
        buf.withBytes { allBytes in
            for (i, m) in top.enumerated() {
                let p = m.points
                let positions: [UInt16]
                if normalizedQuery.isEmpty {
                    positions = []
                } else {
                    let slice = UnsafeBufferPointer(
                        start: allBytes.baseAddress! + Int(m.item.offset),
                        count: Int(m.item.length)
                    )
                    positions = matcher.matchForHighlight(prepared, textBuf: slice, buffer: &scratch)?.positions ?? []
                }
                print("  #\(i + 1)  score=\(m.score)  pts=(\(p >> 48 & 0xFFFF),\(p >> 32 & 0xFFFF),\(p >> 16 & 0xFFFF),\(p & 0xFFFF))  pos=\(positions)  \(m.item.text(in: buf))")
            }
        }
    }

    public func run() async throws {
        // Initialize components
        let cache = ItemCache()
        let reader = StdinReader(cache: cache)

        // Start reading stdin in background (non-blocking!)
        let readTask = await reader.startReading()

        // Wait briefly for initial items to load
        try? await Task.sleep(for: .milliseconds(100))

        // Determine preview style.  Priority: --preview / --preview-float → FLTR_PREVIEW_COMMAND.
        // nil when none of the three is set — Ctrl-O becomes a no-op.
        let previewCommand = options.preview ?? options.previewFloat
            ?? ProcessInfo.processInfo.environment["FLTR_PREVIEW_COMMAND"]
        let useFloatingPreview = options.previewFloat != nil

        // Initialize UI components
        let terminal = RawTerminal()
        let matcher = FuzzyMatcher(caseSensitive: options.caseSensitive, scheme: options.scheme)
        let ui = UIController(
            terminal: terminal,
            matcher: matcher,
            cache: cache,
            reader: reader,
            maxHeight: options.height,
            multiSelect: options.multi,
            previewCommand: previewCommand,
            useFloatingPreview: useFloatingPreview
        )

        // Run UI (starts immediately, even if stdin still reading)
        let selectedItems = try await ui.run()

        // Cancel background reading if still active
        readTask.cancel()

        // Output results
        let outputBuf = cache.buffer
        for item in selectedItems {
            print(item.text(in: outputBuf))
        }
    }
}
