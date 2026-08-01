import Foundation

/// A status bar widget for displaying counts, progress, and loading state.
///
/// Provides a configurable status bar that can show:
/// - Match counts (e.g., "100/1000")
/// - Selection counts (e.g., "5 selected")
/// - Loading spinner animation
public struct StatusBar: Sendable {
    /// Configuration for status bar rendering
    public struct Config: Sendable {
        public let matchedCount: Int
        public let totalCount: Int
        public let selectedCount: Int
        public let isLoading: Bool
        public let searchProgressCompleted: Int?
        public let searchProgressTotal: Int
        public let spinnerFrame: Int
        public let scrollOffset: Int
        public let displayHeight: Int
        public let row: Int
        public let width: Int
        
        public init(
            matchedCount: Int,
            totalCount: Int,
            selectedCount: Int = 0,
            isLoading: Bool = false,
            searchProgressCompleted: Int? = nil,
            searchProgressTotal: Int = 0,
            spinnerFrame: Int = 0,
            scrollOffset: Int = 0,
            displayHeight: Int = 0,
            row: Int,
            width: Int
        ) {
            self.matchedCount = matchedCount
            self.totalCount = totalCount
            self.selectedCount = selectedCount
            self.isLoading = isLoading
            self.searchProgressCompleted = searchProgressCompleted
            self.searchProgressTotal = searchProgressTotal
            self.spinnerFrame = spinnerFrame
            self.scrollOffset = scrollOffset
            self.displayHeight = displayHeight
            self.row = row
            self.width = width
        }
    }
    
    private let spinner: Spinner
    
    /// Initialize a status bar with the specified spinner style.
    ///
    /// - Parameter spinnerStyle: The spinner animation style (default: .braille)
    public init(spinnerStyle: Spinner.Style = .braille) {
        self.spinner = Spinner(style: spinnerStyle)
    }
    
    /// Render the status bar with the given configuration.
    ///
    /// - Parameter config: Status bar configuration
    /// - Returns: ANSI-formatted string for the status bar
    public func render(config: Config) -> String {
        // Show spinner on the left if loading
        let prefix = config.isLoading ? spinner.frame(at: config.spinnerFrame) + " " : ""
        
        var status: String
        if config.selectedCount == 0 {
            status = "\(config.matchedCount)/\(config.totalCount)"
        } else {
            status = "\(config.matchedCount)/\(config.totalCount) (\(config.selectedCount) selected)"
        }

        if let completed = config.searchProgressCompleted {
            status += " · searching \(completed)/\(config.searchProgressTotal)"
        }
        
        return ANSIColors.moveCursor(row: config.row, col: 1) + 
               ANSIColors.clearLineToEnd + 
               TextRenderer.pad(prefix + status, width: config.width)
    }
}
