import Foundation
import TUI

/// Handles keyboard and mouse input parsing and routing
struct InputHandler: Sendable {
    let multiSelect: Bool
    let hasPreview: Bool

    /// Handle key event and update state, return action to take
    func handleKeyEvent(
        key: Key,
        state: inout UIState,
        context: InputContext
    ) -> InputAction {
        switch key {
        case .char(let char):
            state.addChar(char)
            return .scheduleMatchUpdate

        case .backspace:
            state.deleteChar()
            return .scheduleMatchUpdate

        case .enter:
            state.shouldExit = true
            state.exitWithSelection = true
            return .none

        case .escape, .ctrlC:
            state.shouldExit = true
            state.exitWithSelection = false
            return .none

        case .ctrlU:
            state.clearQuery()
            return .scheduleMatchUpdate

        case .ctrlK:
            state.deleteToEndOfLine()
            return .scheduleMatchUpdate

        case .ctrlA:
            state.moveCursorToStart()
            return .none

        case .ctrlE:
            state.moveCursorToEnd()
            return .none

        case .ctrlF:
            state.moveCursorRight()
            return .none

        case .ctrlB:
            state.moveCursorLeft()
            return .none

        case .ctrlV:
            state.pageDown(visibleHeight: context.visibleHeight)
            return .updatePreview

        case .altV:
            state.pageUp(visibleHeight: context.visibleHeight)
            return .updatePreview

        case .left:
            state.moveCursorLeft()
            return .none

        case .right:
            state.moveCursorRight()
            return .none

        case .up:
            state.moveUp(visibleHeight: context.visibleHeight)
            return .updatePreview

        case .down:
            state.moveDown(visibleHeight: context.visibleHeight)
            return .updatePreview

        case .tab:
            if multiSelect {
                state.toggleSelection()
            }
            return .none

        case .ctrlO:
            // Toggle preview window (style depends on useFloatingPreview flag)
            if hasPreview {
                return .togglePreview
            }
            return .none

        case .mouseScrollUp(let col, let row):
            if let bounds = context.previewBounds, bounds.contains(col: col, row: row) {
                // Scroll preview up (decrease offset)
                let newOffset = max(0, context.previewScrollOffset - 3)
                return .updatePreviewScroll(offset: newOffset)
            } else {
                // Scroll list up
                state.moveUp(visibleHeight: context.visibleHeight)
                return .updatePreview
            }

        case .mouseScrollDown(let col, let row):
            if let bounds = context.previewBounds, bounds.contains(col: col, row: row) {
                // Scroll preview down (increase offset)
                let lines = context.cachedPreview.split(separator: "\n", omittingEmptySubsequences: false)
                let maxOffset = max(0, lines.count - 1)
                let newOffset = min(maxOffset, context.previewScrollOffset + 3)
                return .updatePreviewScroll(offset: newOffset)
            } else {
                // Scroll list down
                state.moveDown(visibleHeight: context.visibleHeight)
                return .updatePreview
            }

        default:
            return .none
        }
    }
}

/// Context for input handling operations
struct InputContext: Sendable {
    let visibleHeight: Int
    let cachedPreview: String
    let previewScrollOffset: Int
    let previewBounds: Bounds?
}

/// Action to take after handling input
enum InputAction: Sendable {
    case none
    case scheduleMatchUpdate
    case updatePreview
    case updatePreviewScroll(offset: Int)
    case togglePreview
}
