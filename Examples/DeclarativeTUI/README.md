# DeclarativeTUI

A SwiftUI-style declarative framework for building terminal user interfaces in Swift.

## Overview

DeclarativeTUI provides a declarative, composable API for building TUI applications, inspired by SwiftUI. It hides the complexity of terminal control and provides a clean, type-safe interface for building interactive terminal applications.

## Features

- **Declarative syntax** - Build UIs with result builders
- **Composable views** - VStack, HStack, Text, Divider, SpinnerView, and more
- **Chainable modifiers** - `.bold()`, `.foregroundColor()`, etc.
- **Type safety** - All views are checked at compile time
- **Sendable conformance** - Safe for Swift 6 concurrency
- **Unicode/IME-friendly rendering** - Handles emoji/CJK text and keeps IME candidate UI anchored to the input caret

## Quick Start

```swift
import DeclarativeTUI

@main
struct MyApp {
    static func main() async {
        let app = App(rootView:
            VStack(spacing: 2) {
                Text("Welcome to DeclarativeTUI")
                    .bold()
                    .foregroundColor(Colors.orange)
                
                Divider()
                
                Text("Press ESC to exit")
                    .foregroundColor(Colors.dim)
            }
        )
        
        try? await app.run()
    }
}
```

## Views

### Basic Views

- **Text** - Display text with optional styling
- **SpinnerView** - Animated loading spinner
- **Divider** - Horizontal separator line
- **Spacer** - Empty space

### Layout Containers

- **VStack** - Vertical stack with configurable spacing
- **HStack** - Horizontal stack with configurable spacing

### View Modifiers

- `.bold()` - Make text bold
- `.foregroundColor(String)` - Set text color

## Colors

Use the `Colors` enum for terminal colors:

- `Colors.orange` - Swift orange
- `Colors.green` - Green
- `Colors.dim` - Dimmed text
- `Colors.reset` - Reset formatting

## Example: Complete App

```swift
import DeclarativeTUI

@main
struct TodoApp {
    static func main() async {
        let app = App(rootView:
            VStack(spacing: 1) {
                Text("📝 Todo List")
                    .bold()
                    .foregroundColor(Colors.orange)
                
                Divider()
                
                HStack {
                    Text("•")
                    Text("Write documentation")
                }
                
                HStack {
                    Text("•")
                    Text("Add more views")
                }
                
                Divider(style: .dashed)
                
                Text("Press ESC to exit")
                    .foregroundColor(Colors.dim)
            }
        )
        
        try? await app.run()
    }
}
```

## Architecture

DeclarativeTUI is built on top of the imperative TUI library but hides those details:

```
DeclarativeTUI (declarative API)
    ↓
TUI (imperative widgets)
    ↓
Terminal control (ANSI codes, raw mode)
```

Consumers of DeclarativeTUI only see the declarative layer and don't need to interact with terminal primitives directly.

## Limitations (PoC)

Current limitations in this proof-of-concept:

1. Layout is simplified - no proper size measurement
2. No state management (`@State`, `@Binding`)
3. Limited view types
4. No conditional rendering in result builder
5. Fixed event loop (only ESC to exit)

## Future Enhancements

Possible improvements:

- State management with property wrappers
- More views (Button, TextField, List, etc.)
- Proper layout system with size measurement
- Event handling and callbacks
- Conditional rendering support
- Animation system
- Theming support
