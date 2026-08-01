import Foundation
import TUI

/// Handles all UI rendering operations
struct UIRenderer: Sendable {
    let maxHeight: Int?
    let multiSelect: Bool

    /// Status bar widget
    private static let statusBar = StatusBar()
    /// Horizontal separator widget
    private static let separator = HorizontalSeparator()

    /// Assemble complete frame buffer for rendering.
    /// *visibleItems* is the already-sliced window from the caller (UIController
    /// materialises it from the ResultMerger so we never need a mutable merger here).
    func assembleFrame(
        state: UIState,
        visibleItems: [MatchedItem],
        highlightPositions: [Item.Index: [UInt16]],
        context: RenderContext,
        buffer: TextBuffer
    ) -> String {
        let (rows, cols) = (context.rows, context.cols)

        // Calculate available rows for items
        // Layout: row 1 = input, row 2 = divider and status, rows 3..N = items.
        let availableRows = rows - 3  // input, combined chrome row, and one spare row
        let displayHeight = maxHeight.map { min($0, availableRows) } ?? availableRows

        // Calculate layout based on preview mode
        let listWidth: Int

        if context.showSplitPreview {
            // Split-screen: 50/50 layout with vertical separator
            listWidth = cols / 2 - 1
        } else {
            // Full width for list
            listWidth = cols
        }

        let showsScrollBar = state.matchCount > displayHeight
        // Reserve one cell so the scrollbar never overwrites an item character.
        let itemListWidth = showsScrollBar ? max(1, listWidth - 1) : listWidth

        // Build entire frame in a single string to minimize actor calls
        var frame = ""

        // Clear screen
        frame += ANSIColors.clearScreen

        // Render input line (positions itself) - use full width
        frame += renderInputLine(query: state.query, cursorPosition: state.cursorPosition, cols: cols)

        // Render the divider directly below the query, then overlay its stable
        // status text so the line continues to the right of the count.
        frame += renderBorderLine(row: 2, cols: cols)
        frame += renderStatusBar(
            matchedCount: state.matchCount,
            totalItems: state.totalItems,
            selectedItems: state.selectedItems,
            isReadingStdin: context.isReadingStdin,
            searchProgress: context.searchProgress,
            scrollOffset: state.scrollOffset,
            displayHeight: displayHeight,
            row: 2,
            cols: listWidth,
            spinnerFrame: context.spinnerFrame
        )

        // Render matched items (positions each line)
        frame += renderItemList(
            visibleItems: visibleItems,
            highlightPositions: highlightPositions,
            selectedIndex: state.selectedIndex,
            selectedItems: state.selectedItems,
            scrollOffset: state.scrollOffset,
            cols: itemListWidth,
            textBuffer: buffer
        )

        if showsScrollBar {
            frame += renderScrollBar(
                matchedCount: state.matchCount,
                scrollOffset: state.scrollOffset,
                displayHeight: displayHeight,
                row: 3,
                col: listWidth
            )
        }

        // Keep terminal cursor anchored to the prompt caret position.
        // IME candidate UI follows the terminal cursor location.
        frame += inputCursorAnchor(query: state.query, cursorPosition: state.cursorPosition, cols: cols)

        return frame
    }

    /// Render input line with cursor
    func renderInputLine(query: String, cursorPosition: Int, cols: Int) -> String {
        let prompt = "> "
        let availableWidth = cols - prompt.count - 1

        // ANSI codes for cursor (inverted colors)
        let cursorStart = ANSIColors.reverse
        let cursorEnd = ANSIColors.normalVideo

        var displayText = ""

        if query.isEmpty {
            // Show cursor at empty position
            displayText = cursorStart + " " + cursorEnd
        } else {
            // Insert cursor into query string
            let queryChars = Array(query)
            for (index, char) in queryChars.enumerated() {
                if index == cursorPosition {
                    displayText += cursorStart + String(char) + cursorEnd
                } else {
                    displayText += String(char)
                }
            }

            // If cursor is at the end, show space cursor
            if cursorPosition >= queryChars.count {
                displayText += cursorStart + " " + cursorEnd
            }
        }

        // Truncate if too long (preserving ANSI codes is handled by visual width)
        let displayQuery = TextRenderer.truncate(displayText, width: availableWidth)

        return ANSIColors.moveCursor(row: 1, col: 1) + prompt + displayQuery + ANSIColors.clearLineToEnd
    }

    /// Render horizontal border line
    private func renderBorderLine(row: Int, cols: Int) -> String {
        return Self.separator.render(row: row, width: cols)
    }

    /// Render item list with highlighting.
    /// *visibleItems* is already the scrolled window; *scrollOffset* is used
    /// only to map display indices back to global indices for selection checks.
    private func renderItemList(
        visibleItems: [MatchedItem],
        highlightPositions: [Item.Index: [UInt16]],
        selectedIndex: Int,
        selectedItems: Set<Item.Index>,
        scrollOffset: Int,
        cols: Int,
        textBuffer: TextBuffer
    ) -> String {
        var buffer = ""
        for (displayIndex, matchedItem) in visibleItems.enumerated() {
            let row = displayIndex + 3  // Below the input and combined chrome row.
            let actualIndex = scrollOffset + displayIndex

            let isSelected = selectedIndex == actualIndex
            let isMarked = selectedItems.contains(matchedItem.item.index)

            var prefix = "  "
            if isMarked {
                prefix = " \(ANSIColors.swiftOrange)>\(ANSIColors.normalIntensity)\(ANSIColors.resetForeground)"
            }
            if isSelected {
                if isMarked {
                    prefix = "\(ANSIColors.swiftOrange)>>\(ANSIColors.normalIntensity)\(ANSIColors.resetForeground)"
                } else {
                    prefix = " \(ANSIColors.swiftOrange)>\(ANSIColors.normalIntensity)\(ANSIColors.resetForeground)"
                }
            }

            // Apply background color for selected line
            let bgStart = isSelected ? ANSIColors.grayBackground : ""
            let bgEnd = isSelected ? ANSIColors.reset : ""

            let text = matchedItem.item.text(in: textBuffer)
            let prefixVisualWidth = 2
            let availableWidth = cols - prefixVisualWidth - 1

            // Truncate and highlight
            let displayText = TextRenderer.truncateAndHighlight(
                text,
                positions: highlightPositions[matchedItem.item.index] ?? [],
                width: availableWidth
            )

            // Pad line to full width
            let content = prefix + displayText
            let paddedLine = TextRenderer.padWithoutANSI(content, width: cols - 1)

            // Position cursor and write line
            buffer += ANSIColors.moveCursor(row: row, col: 1) + ANSIColors.clearLineToEnd
            buffer += bgStart + paddedLine + bgEnd
        }

        return buffer
    }

    /// Render status bar
    private func renderStatusBar(
        matchedCount: Int,
        totalItems: Int,
        selectedItems: Set<Item.Index>,
        isReadingStdin: Bool,
        searchProgress: SearchProgress.Snapshot?,
        scrollOffset: Int,
        displayHeight: Int,
        row: Int,
        cols: Int,
        spinnerFrame: Int
    ) -> String {
        let config = StatusBar.Config(
            matchedCount: matchedCount,
            totalCount: totalItems,
            selectedCount: selectedItems.count,
            isLoading: isReadingStdin || searchProgress != nil,
            searchProgressCompleted: searchProgress?.completed,
            searchProgressTotal: searchProgress?.total ?? 0,
            spinnerFrame: spinnerFrame,
            scrollOffset: scrollOffset,
            displayHeight: displayHeight,
            row: row,
            width: cols
        )
        return ANSIColors.moveCursor(row: row, col: 1) + Self.statusBar.content(config: config)
    }

    /// Render a compact viewport scrollbar beside the result rows. The thumb
    /// represents the visible window within the complete result set.
    private func renderScrollBar(
        matchedCount: Int,
        scrollOffset: Int,
        displayHeight: Int,
        row: Int,
        col: Int
    ) -> String {
        guard displayHeight > 0, matchedCount > displayHeight else { return "" }

        let maxScroll = matchedCount - displayHeight
        // Keep at least one track cell visible so a nearly full viewport still
        // communicates that additional rows exist.
        let thumbHeight = min(
            displayHeight - 1,
            max(1, (displayHeight * displayHeight + matchedCount - 1) / matchedCount)
        )
        let maxThumbStart = displayHeight - thumbHeight
        let clampedOffset = min(max(0, scrollOffset), maxScroll)
        let thumbStart = maxScroll == 0 ? 0 : (clampedOffset * maxThumbStart) / maxScroll

        var buffer = ""
        for index in 0..<displayHeight {
            let glyph = index >= thumbStart && index < thumbStart + thumbHeight ? "█" : "│"
            buffer += ANSIColors.moveCursor(row: row + index, col: col) + glyph
        }
        return buffer
    }

    private func inputCursorAnchor(query: String, cursorPosition: Int, cols: Int) -> String {
        let prompt = "> "
        let availableWidth = max(0, cols - prompt.count - 1)
        let prefix = String(query.prefix(max(0, min(cursorPosition, query.count))))
        let prefixWidth = min(availableWidth, TextRenderer.visualWidth(prefix))
        let col = min(cols, max(1, prompt.count + 1 + prefixWidth))
        return ANSIColors.moveCursor(row: 1, col: col)
    }
}

/// Context for rendering operations
struct RenderContext: Sendable {
    let rows: Int
    let cols: Int
    let isReadingStdin: Bool
    let searchProgress: SearchProgress.Snapshot?
    let showSplitPreview: Bool
    let showFloatingPreview: Bool
    let spinnerFrame: Int
}
