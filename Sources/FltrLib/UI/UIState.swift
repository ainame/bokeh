import Foundation

/// UI state management
struct UIState: Sendable {
    var query: String = ""
    var previousQuery: String = ""  // For incremental filtering optimization
    // Grapheme-cluster index into `query` (same indexing model as `Array(query)`).
    var cursorPosition: Int = 0
    var selectedIndex: Int = 0
    var scrollOffset: Int = 0  // First visible item index
    var selectedItems: Set<Item.Index> = []
    var merger: ResultMerger = .empty
    var matchCount: Int = 0  // = merger.count; cached so the renderer can read it from a by-value copy
    var totalItems: Int = 0
    var shouldExit: Bool = false
    var exitWithSelection: Bool = false

    mutating func addChar(_ char: Character) {
        // Insert character at cursor position
        let index = cursorIndex()
        query.insert(char, at: index)
        cursorPosition += 1
    }

    mutating func deleteChar() {
        // Delete character before cursor (backspace behavior)
        guard cursorPosition > 0 else { return }
        let index = query.index(before: cursorIndex())
        query.remove(at: index)
        cursorPosition -= 1
    }

    mutating func clearQuery() {
        query = ""
        cursorPosition = 0
    }

    mutating func moveCursorLeft() {
        if cursorPosition > 0 {
            cursorPosition -= 1
        }
    }

    mutating func moveCursorRight() {
        if cursorPosition < query.count {
            cursorPosition += 1
        }
    }

    mutating func moveCursorToStart() {
        cursorPosition = 0
    }

    mutating func moveCursorToEnd() {
        cursorPosition = query.count
    }

    mutating func deleteToEndOfLine() {
        // Delete from cursor position to end of line (Emacs Ctrl-K behavior)
        guard cursorPosition < query.count else { return }
        let startIndex = cursorIndex()
        query.removeSubrange(startIndex..<query.endIndex)
        // Cursor position stays the same (now at end)
    }

    mutating func moveUp(visibleHeight: Int) {
        if selectedIndex > 0 {
            selectedIndex -= 1
            // Scroll up if selected item goes above visible area
            if selectedIndex < scrollOffset {
                scrollOffset = selectedIndex
            }
        }
    }

    mutating func moveDown(visibleHeight: Int) {
        if selectedIndex < matchCount - 1 {
            selectedIndex += 1
            // Scroll down if selected item goes below visible area
            let lastVisibleIndex = scrollOffset + visibleHeight - 1
            if selectedIndex > lastVisibleIndex {
                scrollOffset = selectedIndex - visibleHeight + 1
            }
        }
    }

    mutating func pageDown(visibleHeight: Int) {
        // Move down by a full page (visibleHeight)
        let newIndex = min(selectedIndex + visibleHeight, matchCount - 1)
        if newIndex != selectedIndex {
            selectedIndex = newIndex
            // Adjust scroll offset to keep selection visible
            let lastVisibleIndex = scrollOffset + visibleHeight - 1
            if selectedIndex > lastVisibleIndex {
                scrollOffset = selectedIndex - visibleHeight + 1
            }
        }
    }

    mutating func pageUp(visibleHeight: Int) {
        // Move up by a full page (visibleHeight)
        let newIndex = max(selectedIndex - visibleHeight, 0)
        if newIndex != selectedIndex {
            selectedIndex = newIndex
            // Adjust scroll offset to keep selection visible
            if selectedIndex < scrollOffset {
                scrollOffset = selectedIndex
            }
        }
    }

    mutating func toggleSelection() {
        guard let item = merger.get(selectedIndex) else { return }
        let itemIndex = item.item.index

        if selectedItems.contains(itemIndex) {
            selectedItems.remove(itemIndex)
        } else {
            selectedItems.insert(itemIndex)
        }
    }

    mutating func updateMatches(_ newMerger: ResultMerger) {
        merger = newMerger
        matchCount = merger.count
        if selectedIndex >= matchCount {
            selectedIndex = max(0, matchCount - 1)
        }
        // Reset scroll to top when matches change
        scrollOffset = 0
    }

    mutating func getSelectedItems() -> [Item] {
        if !exitWithSelection {
            return []
        }

        if selectedItems.isEmpty {
            // Return current item if nothing explicitly selected
            if let item = merger.get(selectedIndex) {
                return [item.item]
            }
            return []
        }

        // Return all selected items in original order (O(n) scan, only on exit)
        return merger.selectedItems(indices: selectedItems)
    }

    private func cursorIndex() -> String.Index {
        query.index(query.startIndex, offsetBy: cursorPosition)
    }
}
