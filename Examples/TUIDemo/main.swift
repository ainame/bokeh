import Foundation
import TUI
import SystemPackage

@main
struct TUIDemo {
    static func main() async {
        do {
            let demo = WidgetGallery()
            try await demo.run()
        } catch RawTerminal.TerminalError.failedToOpenTTY {
            print("Error: This demo requires a TTY (terminal) to run.")
            print("Please run it directly in your terminal, not through a pipe or redirect.")
            print("\nUsage: swift run --package-path Examples tui-demo")
            exit(1)
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}

/// Interactive TUI widget gallery showcasing all TUI components
actor WidgetGallery {
    // State
    private var currentPage = 0
    private var spinnerFrame = 0
    private var spinnerStyle: Spinner.Style = .braille
    private var separatorStyle: HorizontalSeparator.Style = .light
    private var selectedMenuItem = 0
    
    // Pages
    private let pages = [
        "Welcome",
        "Spinners",
        "Status Bars",
        "Separators",
        "Colors & Text",
        "Bounds Demo",
    ]
    
    func run() async throws {
        let terminal = RawTerminal()

        // Enter raw mode to enable character-by-character input
        try await terminal.enterRawMode()

        // Enable mouse tracking for scroll events
        await terminal.write("\u{001B}[?1000h\u{001B}[?1006h")

        // Hide cursor
        await terminal.write("\u{001B}[?25l")
        
        defer {
            // Cleanup: show cursor, disable mouse tracking, and exit raw mode
            Task {
                await terminal.write("\u{001B}[?25h\u{001B}[?1000l\u{001B}[?1006l")
                await terminal.write(ANSIColors.clearScreen + ANSIColors.moveCursor(row: 1, col: 1))
                await terminal.exitRawMode()
            }
        }
        
        // Initial render
        try await render(terminal: terminal)
        
        // Spinner animation task (matches fltr's 100ms refresh interval)
        let animationTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                self.advanceSpinner()
                try? await self.render(terminal: terminal)
            }
        }
        
        // Main event loop
        while true {
            guard let key = await terminal.readInputEvent() else {
                // readInputEvent() returns nil when no complete event is available.
                // Only exit if the terminal is broken (closed/disconnected)
                if await terminal.ttyBroken {
                    break
                }
                // Otherwise continue polling
                continue
            }

            // Handle key event
            let shouldExit = handleKey(key)
            if shouldExit {
                break
            }
            
            try await render(terminal: terminal)
        }
        
        animationTask.cancel()
    }
    
    private func advanceSpinner() {
        spinnerFrame += 1
    }

    private func handleKey(_ key: Key) -> Bool {
        switch key {
        case .escape, .ctrlC, .char("q"):
            return true
            
        case .left, .char("h"):
            currentPage = max(0, currentPage - 1)
            
        case .right, .char("l"):
            currentPage = min(pages.count - 1, currentPage + 1)
            
        case .up, .char("k"):
            selectedMenuItem = max(0, selectedMenuItem - 1)
            
        case .down, .char("j"):
            selectedMenuItem = min(getMenuItemsCount() - 1, selectedMenuItem + 1)
            
        case .enter, .char(" "):
            handleMenuSelect()
            
        default:
            break
        }
        
        return false
    }
    
    private func getMenuItemsCount() -> Int {
        switch currentPage {
        case 1: return 3 // Spinner styles
        case 3: return 4 // Separator styles
        default: return 0
        }
    }
    
    private func handleMenuSelect() {
        switch currentPage {
        case 1: // Spinner page
            switch selectedMenuItem {
            case 0: spinnerStyle = .braille
            case 1: spinnerStyle = .dots
            case 2: spinnerStyle = .arrow
            default: break
            }
            
        case 3: // Separator page
            switch selectedMenuItem {
            case 0: separatorStyle = .light
            case 1: separatorStyle = .heavy
            case 2: separatorStyle = .double
            case 3: separatorStyle = .dashed
            default: break
            }
            
        default:
            break
        }
    }
    
    private func render(terminal: any Terminal) async throws {
        var buffer = ANSIColors.clearScreen

        // Get terminal size using terminal's getSize() method
        let (rows, cols) = await getTerminalSize(terminal: terminal)

        // Render header
        buffer += renderHeader(cols: cols)
        
        // Render navigation
        buffer += renderNavigation(row: 3, cols: cols)
        
        // Render separator
        let separator = HorizontalSeparator()
        buffer += separator.render(row: 4, width: cols)
        
        // Render current page content
        buffer += renderPage(startRow: 5, endRow: rows - 3, cols: cols)
        
        // Render footer
        buffer += renderFooter(row: rows - 1, cols: cols)

        await terminal.write(buffer)
    }
    
    private func getTerminalSize(terminal: any Terminal) async -> (rows: Int, cols: Int) {
        // Use terminal's getSize() method for accurate detection
        if let size = try? await terminal.getSize() {
            return size
        }
        // Fallback to defaults if detection fails
        return (24, 80)
    }
    
    private func renderHeader(cols: Int) -> String {
        let title = " TUI Widget Gallery "
        let subtitle = "Interactive demo of TUI library components"
        
        var buffer = ""
        
        // Title (centered, bold, orange)
        let titlePadding = max(0, (cols - title.count) / 2)
        buffer += ANSIColors.moveCursor(row: 1, col: 1) + ANSIColors.clearLineToEnd
        buffer += String(repeating: " ", count: titlePadding)
        buffer += ANSIColors.bold + ANSIColors.swiftOrange + title + ANSIColors.reset

        // Subtitle (centered, dim)
        let subtitlePadding = max(0, (cols - subtitle.count) / 2)
        buffer += ANSIColors.moveCursor(row: 2, col: 1) + ANSIColors.clearLineToEnd
        buffer += String(repeating: " ", count: subtitlePadding)
        buffer += ANSIColors.dim + subtitle + ANSIColors.reset
        
        return buffer
    }
    
    private func renderNavigation(row: Int, cols: Int) -> String {
        var buffer = ANSIColors.moveCursor(row: row, col: 1) + ANSIColors.clearLineToEnd
        
        let totalWidth = pages.enumerated().map { (idx, page) in
            return page.count + 4 // "[" + page + "]" + " "
        }.reduce(0, +)

        let leftPadding = max(0, (cols - totalWidth) / 2)
        buffer += String(repeating: " ", count: leftPadding)
        
        for (idx, page) in pages.enumerated() {
            if idx == currentPage {
                buffer += ANSIColors.swiftOrange + "[" + page + "]" + ANSIColors.reset
            } else {
                buffer += ANSIColors.dim + " " + page + " " + ANSIColors.reset
            }
            buffer += " "
        }
        
        return buffer
    }
    
    private func renderPage(startRow: Int, endRow: Int, cols: Int) -> String {
        let contentHeight = endRow - startRow
        
        switch currentPage {
        case 0: return renderWelcomePage(startRow: startRow, cols: cols, height: contentHeight)
        case 1: return renderSpinnersPage(startRow: startRow, cols: cols, height: contentHeight)
        case 2: return renderStatusBarsPage(startRow: startRow, cols: cols, height: contentHeight)
        case 3: return renderSeparatorsPage(startRow: startRow, cols: cols, height: contentHeight)
        case 4: return renderColorsPage(startRow: startRow, cols: cols, height: contentHeight)
        case 5: return renderBoundsPage(startRow: startRow, cols: cols, height: contentHeight)
        default: return ""
        }
    }
    
    private func renderWelcomePage(startRow: Int, cols: Int, height: Int) -> String {
        var buffer = ""
        var row = startRow + 2
        
        let lines = [
            "Welcome to the TUI Widget Gallery!",
            "",
            "This interactive demo showcases the widgets and utilities",
            "available in the TUI library.",
            "",
            "Navigation:",
            "  ← → or h/l  : Switch between pages",
            "  ↑ ↓ or k/j  : Navigate menu items",
            "  Enter/Space : Select menu item",
            "  ESC or q    : Exit",
            "",
            "The TUI library includes:",
            "  • Spinner animations",
            "  • Status bars with progress indicators",
            "  • Separators with multiple styles",
            "  • ANSI color utilities",
            "  • Text rendering with truncation",
            "  • Geometric bounds for layouts",
        ]
        
        let leftPadding = 4
        for line in lines {
            buffer += ANSIColors.moveCursor(row: row, col: leftPadding)
            buffer += line
            row += 1
        }
        
        return buffer
    }
    
    private func renderSpinnersPage(startRow: Int, cols: Int, height: Int) -> String {
        var buffer = ""
        var row = startRow + 2
        
        buffer += ANSIColors.moveCursor(row: row, col: 4)
        buffer += ANSIColors.bold + "Spinner Widget" + ANSIColors.reset
        row += 2
        
        let spinner = Spinner(style: spinnerStyle)
        
        buffer += ANSIColors.moveCursor(row: row, col: 4)
        buffer += "Current animation: " + ANSIColors.swiftOrange + spinner.frame(at: spinnerFrame) + ANSIColors.reset
        row += 2
        
        buffer += ANSIColors.moveCursor(row: row, col: 4)
        buffer += "Select a style:"
        row += 1
        
        let styles: [(String, Spinner.Style)] = [
            ("Braille (compact, default)", .braille),
            ("Dots (simple)", .dots),
            ("Arrow (directional)", .arrow),
        ]
        
        for (idx, (name, style)) in styles.enumerated() {
            buffer += ANSIColors.moveCursor(row: row + idx, col: 6)
            
            let marker = selectedMenuItem == idx ? ANSIColors.swiftOrange + "▸" + ANSIColors.reset : " "
            let highlight = style == spinnerStyle ? ANSIColors.green : ""
            let reset = style == spinnerStyle ? ANSIColors.reset : ""
            
            buffer += marker + " " + highlight + name + reset
            
            // Show preview
            let previewSpinner = Spinner(style: style)
            buffer += "  " + previewSpinner.frame(at: spinnerFrame)
        }
        
        return buffer
    }
    
    private func renderStatusBarsPage(startRow: Int, cols: Int, height: Int) -> String {
        var buffer = ""
        var row = startRow + 2
        
        buffer += ANSIColors.moveCursor(row: row, col: 4)
        buffer += ANSIColors.bold + "StatusBar Widget" + ANSIColors.reset
        row += 2
        
        buffer += ANSIColors.moveCursor(row: row, col: 4)
        buffer += "The StatusBar widget displays counts, progress, and loading state."
        row += 2
        
        // Example 1: Basic status
        buffer += ANSIColors.moveCursor(row: row, col: 4)
        buffer += "Example 1: Basic counts"
        row += 1
        
        let statusBar1 = StatusBar()
        let config1 = StatusBar.Config(
            matchedCount: 42,
            totalCount: 100,
            row: row,
            width: cols - 8
        )
        buffer += ANSIColors.moveCursor(row: row, col: 8)
        buffer += statusBar1.render(config: config1)
        row += 2
        
        // Example 2: With selection
        buffer += ANSIColors.moveCursor(row: row, col: 4)
        buffer += "Example 2: With selection"
        row += 1
        
        let config2 = StatusBar.Config(
            matchedCount: 42,
            totalCount: 100,
            selectedCount: 5,
            row: row,
            width: cols - 8
        )
        buffer += ANSIColors.moveCursor(row: row, col: 8)
        buffer += statusBar1.render(config: config2)
        row += 2
        
        // Example 3: With loading spinner
        buffer += ANSIColors.moveCursor(row: row, col: 4)
        buffer += "Example 3: Loading state with spinner"
        row += 1
        
        let config3 = StatusBar.Config(
            matchedCount: 42,
            totalCount: 100,
            selectedCount: 3,
            isLoading: true,
            spinnerFrame: spinnerFrame,
            row: row,
            width: cols - 8
        )
        buffer += ANSIColors.moveCursor(row: row, col: 8)
        buffer += statusBar1.render(config: config3)
        row += 2
        
        // Example 4: With scroll indicator
        buffer += ANSIColors.moveCursor(row: row, col: 4)
        buffer += "Example 4: With scroll progress"
        row += 1
        
        let config4 = StatusBar.Config(
            matchedCount: 100,
            totalCount: 200,
            scrollOffset: 25,
            displayHeight: 10,
            row: row,
            width: cols - 8
        )
        buffer += ANSIColors.moveCursor(row: row, col: 8)
        buffer += statusBar1.render(config: config4)
        
        return buffer
    }
    
    private func renderSeparatorsPage(startRow: Int, cols: Int, height: Int) -> String {
        var buffer = ""
        var row = startRow + 2
        
        buffer += ANSIColors.moveCursor(row: row, col: 4)
        buffer += ANSIColors.bold + "HorizontalSeparator Widget" + ANSIColors.reset
        row += 2
        
        buffer += ANSIColors.moveCursor(row: row, col: 4)
        buffer += "Select a style:"
        row += 1
        
        let styles: [(String, HorizontalSeparator.Style)] = [
            ("Light (default)", .light),
            ("Heavy", .heavy),
            ("Double", .double),
            ("Dashed", .dashed),
        ]
        
        for (idx, (name, style)) in styles.enumerated() {
            buffer += ANSIColors.moveCursor(row: row, col: 6)
            
            let marker = selectedMenuItem == idx ? ANSIColors.swiftOrange + "▸" + ANSIColors.reset : " "
            let highlight = style == separatorStyle ? ANSIColors.green : ""
            let reset = style == separatorStyle ? ANSIColors.reset : ""
            
            buffer += marker + " " + highlight + name + reset
            row += 1
        }
        
        row += 1
        buffer += ANSIColors.moveCursor(row: row, col: 4)
        buffer += "Preview:"
        row += 1
        
        let separator = HorizontalSeparator(style: separatorStyle)
        buffer += separator.render(row: row, width: cols - 8)
        
        return buffer
    }
    
    private func renderColorsPage(startRow: Int, cols: Int, height: Int) -> String {
        var buffer = ""
        var row = startRow + 2
        
        buffer += ANSIColors.moveCursor(row: row, col: 4)
        buffer += ANSIColors.bold + "ANSIColors & TextRenderer" + ANSIColors.reset
        row += 2
        
        // Basic colors
        buffer += ANSIColors.moveCursor(row: row, col: 4)
        buffer += "Basic colors:"
        row += 1
        
        let colors = [
            ("Red", ANSIColors.red),
            ("Green", ANSIColors.green),
            ("Yellow", ANSIColors.yellow),
            ("Blue", ANSIColors.blue),
            ("Magenta", ANSIColors.magenta),
            ("Cyan", ANSIColors.cyan),
        ]
        
        for (name, color) in colors {
            buffer += ANSIColors.moveCursor(row: row, col: 6)
            buffer += color + "■ " + name + ANSIColors.reset
            row += 1
        }
        
        row += 1
        
        // Text styles
        buffer += ANSIColors.moveCursor(row: row, col: 4)
        buffer += "Text styles:"
        row += 1
        
        buffer += ANSIColors.moveCursor(row: row, col: 6)
        buffer += ANSIColors.bold + "Bold text" + ANSIColors.reset
        row += 1
        
        buffer += ANSIColors.moveCursor(row: row, col: 6)
        buffer += ANSIColors.dim + "Dim text" + ANSIColors.reset
        row += 1
        
        buffer += ANSIColors.moveCursor(row: row, col: 6)
        buffer += ANSIColors.reverse + "Reverse text" + ANSIColors.reset
        row += 1
        
        buffer += ANSIColors.moveCursor(row: row, col: 6)
        buffer += ANSIColors.swiftOrange + "Swift Orange" + ANSIColors.reset
        row += 1
        
        buffer += ANSIColors.moveCursor(row: row, col: 6)
        buffer += ANSIColors.highlightGreen + "Highlight Green" + ANSIColors.reset
        
        return buffer
    }
    
    private func renderBoundsPage(startRow: Int, cols: Int, height: Int) -> String {
        var buffer = ""
        var row = startRow + 2
        
        buffer += ANSIColors.moveCursor(row: row, col: 4)
        buffer += ANSIColors.bold + "Bounds Utility" + ANSIColors.reset
        row += 2
        
        buffer += ANSIColors.moveCursor(row: row, col: 4)
        buffer += "Bounds provide geometric calculations and hit-testing."
        row += 2
        
        // Draw a sample bounded area
        let boxStartRow = row
        let boxStartCol = 10
        let boxWidth = 40
        let boxHeight = 8
        
        let bounds = Bounds(
            startRow: boxStartRow,
            endRow: boxStartRow + boxHeight - 1,
            startCol: boxStartCol,
            endCol: boxStartCol + boxWidth - 1
        )
        
        buffer += ANSIColors.moveCursor(row: row, col: 4)
        buffer += "Sample box (bounded area):"
        row += 1
        
        // Draw box
        for r in 0..<boxHeight {
            buffer += ANSIColors.moveCursor(row: boxStartRow + r, col: boxStartCol)
            if r == 0 {
                // Top border
                buffer += ANSIColors.swiftOrange + "┌" + String(repeating: "─", count: boxWidth - 2) + "┐" + ANSIColors.reset
            } else if r == boxHeight - 1 {
                // Bottom border
                buffer += ANSIColors.swiftOrange + "└" + String(repeating: "─", count: boxWidth - 2) + "┘" + ANSIColors.reset
            } else {
                // Sides
                buffer += ANSIColors.swiftOrange + "│" + ANSIColors.reset
                buffer += String(repeating: " ", count: boxWidth - 2)
                buffer += ANSIColors.swiftOrange + "│" + ANSIColors.reset
            }
        }
        
        // Show bounds info
        buffer += ANSIColors.moveCursor(row: boxStartRow + 2, col: boxStartCol + 2)
        buffer += "bounds.width = \(bounds.width)"
        
        buffer += ANSIColors.moveCursor(row: boxStartRow + 3, col: boxStartCol + 2)
        buffer += "bounds.height = \(bounds.height)"
        
        buffer += ANSIColors.moveCursor(row: boxStartRow + 5, col: boxStartCol + 2)
        buffer += ANSIColors.dim + "Used for mouse hit-testing" + ANSIColors.reset
        buffer += ANSIColors.moveCursor(row: boxStartRow + 6, col: boxStartCol + 2)
        buffer += ANSIColors.dim + "and layout calculations" + ANSIColors.reset
        
        return buffer
    }
    
    private func renderFooter(row: Int, cols: Int) -> String {
        let help = "← → / h l : Navigate  |  ↑ ↓ / k j : Select  |  Enter : Confirm  |  ESC / q : Exit"
        let padding = max(0, (cols - help.count) / 2)

        var buffer = ANSIColors.moveCursor(row: row, col: 1) + ANSIColors.clearLineToEnd
        buffer += String(repeating: " ", count: padding)
        buffer += ANSIColors.dim + help + ANSIColors.reset

        return buffer
    }
}
