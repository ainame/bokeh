import Foundation
import DisplayWidth

/// Text rendering utilities for terminal display.
///
/// Provides Unicode-aware text manipulation for terminal UIs:
/// - Display width calculation (CJK, emoji, grapheme clusters)
/// - ANSI escape sequence preservation
/// - Text truncation and padding
/// - Syntax highlighting support
public struct TextRenderer {
    private static let displayWidth = DisplayWidth()

    /// Returns visual display width in terminal cells.
    public static func visualWidth(_ text: String) -> Int {
        displayWidth(text)
    }

    /// Truncates text to fit specified width, considering Unicode display width and ANSI codes.
    ///
    /// ANSI escape sequences are preserved and don't count toward visual width.
    ///
    /// - Parameters:
    ///   - text: The text to truncate
    ///   - width: Maximum visual width
    /// - Returns: Truncated text with ANSI codes preserved
    public static func truncate(_ text: String, width: Int) -> String {
        // First check if stripping ANSI makes it fit
        let stripped = stripANSI(text)
        let visualWidth = displayWidth(stripped)

        // If it fits, return as-is
        if visualWidth <= width {
            return text
        }

        // Need to truncate - walk through preserving ANSI codes
        var result = ""
        var currentWidth = 0
        var inEscape = false
        var escapeBuffer = ""

        for char in text {
            if char == "\u{001B}" {
                inEscape = true
                escapeBuffer = String(char)
            } else if inEscape {
                escapeBuffer.append(char)
                if char == "m" {
                    // End of escape sequence, add it to result
                    result += escapeBuffer
                    inEscape = false
                    escapeBuffer = ""
                }
            } else {
                // Regular character - check width
                let charWidth = displayWidth(char)
                if currentWidth + charWidth > width {
                    break
                }
                result.append(char)
                currentWidth += charWidth
            }
        }

        return result
    }

    /// Pads text to exact width with spaces.
    ///
    /// - Parameters:
    ///   - text: The text to pad
    ///   - width: Target visual width
    /// - Returns: Padded text
    public static func pad(_ text: String, width: Int) -> String {
        let currentWidth = visualWidth(text)
        if currentWidth >= width {
            return truncate(text, width: width)
        }

        let padding = String(repeating: " ", count: width - currentWidth)
        return text + padding
    }

    /// Highlights matched positions in text with ANSI color codes.
    ///
    /// - Parameters:
    ///   - text: The text to highlight
    ///   - positions: Character positions to highlight
    /// - Returns: Text with highlighted characters
    public static func highlight(_ text: String, positions: [UInt16]) -> String {
        guard !positions.isEmpty else { return text }

        var result = ""
        let chars = Array(text)
        let posSet = Set(positions)

        for (index, char) in chars.enumerated() {
            if posSet.contains(UInt16(index)) {
                // Highlight with bold + green, preserve background
                result += ANSIColors.highlightGreen + "\(char)" + ANSIColors.normalIntensity + ANSIColors.resetForeground
            } else {
                result.append(char)
            }
        }

        return result
    }

    /// Truncates text and then applies highlighting (ANSI-safe).
    ///
    /// This ensures ANSI escape sequences don't break width calculation.
    ///
    /// - Parameters:
    ///   - text: The text to process
    ///   - positions: Character positions to highlight
    ///   - width: Maximum visual width
    /// - Returns: Truncated and highlighted text
    public static func truncateAndHighlight(_ text: String, positions: [UInt16], width: Int) -> String {
        // First truncate to fit width
        var currentWidth = 0
        var truncatedLength = 0

        for char in text {
            let charWidth = displayWidth(char)
            if currentWidth + charWidth > width {
                break
            }
            currentWidth += charWidth
            truncatedLength += 1
        }

        // Get truncated text
        let truncatedText = String(text.prefix(truncatedLength))

        // Filter positions to only include those within truncated range
        let validPositions = positions.filter { Int($0) < truncatedLength }

        // Apply highlighting to truncated text
        return highlight(truncatedText, positions: validPositions)
    }

    /// Pads text that may contain ANSI codes to exact width.
    ///
    /// Strips ANSI codes to calculate visual width, then pads with spaces.
    ///
    /// - Parameters:
    ///   - text: The text to pad (may contain ANSI codes)
    ///   - width: Target visual width
    /// - Returns: Padded text with ANSI codes preserved
    public static func padWithoutANSI(_ text: String, width: Int) -> String {
        // Strip ANSI codes to calculate actual display width
        let stripped = stripANSI(text)
        let currentWidth = displayWidth(stripped)

        if currentWidth >= width {
            return text
        }

        let padding = String(repeating: " ", count: width - currentWidth)
        return text + padding
    }

    /// Strip ANSI escape sequences from text
    private static func stripANSI(_ text: String) -> String {
        var result = ""
        var inEscape = false

        for char in text {
            if char == "\u{001B}" {
                inEscape = true
            } else if inEscape {
                if char == "m" {
                    inEscape = false
                }
            } else {
                result.append(char)
            }
        }

        return result
    }

}
