import Foundation
import TUI

/// A declarative TUI application host
public struct App {
    private let rootView: any TUIView

    public init(rootView: any TUIView) {
        self.rootView = rootView
    }
    
    /// Run the application
    public func run() async throws {
        let terminal = RawTerminal()
        try await terminal.enterRawMode()
        
        defer {
            Task {
                await terminal.exitRawMode()
            }
        }
        
        // Initial render
        try await render(terminal: terminal)
        
        // Main event loop - wait for exit key
        while true {
            guard let key = await terminal.readInputEvent() else {
                if await terminal.ttyBroken {
                    break
                }
                continue
            }

            // Exit on ESC, Ctrl-C, or 'q'
            if key == .escape || key == .ctrlC || key == .char("q") {
                break
            }
        }
    }
    
    private func render(terminal: RawTerminal) async throws {
        let (rows, cols) = try await terminal.getSize()
        
        let context = RenderContext(
            startRow: 1,
            startCol: 1,
            maxWidth: cols,
            maxHeight: rows
        )
        
        let buffer = rootView.render(in: context)
        await terminal.write(buffer)
        await terminal.flush()
    }
}

/// Error types for TUI applications
public enum AppError: Error {
    case failedToOpenTTY
}
