# fltr

A fast, interactive fuzzy finder for the command line. Search through lists with real-time filtering.

```bash
# Find files
find . -type f | fltr

# Filter command history
history | fltr

# Search git branches
git branch | fltr
```

## Installation

### mise

Install the latest release using mise's GitHub backend:

```bash
mise use -g github:ainame/fltr
```

To install this release specifically:

```bash
mise use -g github:ainame/fltr@0.1.0
```

mise selects the archive matching your Apple Silicon (`arm64`) or Intel (`x86_64`) Mac, or x86_64 Linux machine, and places `fltr` on your PATH.

### Local install (host platform)

```bash
git clone <repository-url>
cd fltr
swift build -c release
cp .build/release/fltr /usr/local/bin/
```

### Build Linux static binary (musl + Static Linux SDK)

`make linux` builds `fltr` for Linux using the Swift Static Linux SDK and links `mimalloc` statically.

```bash
git clone <repository-url>
cd fltr

# Build for default target (aarch64)
make linux

# Build for x86_64
ARCH=x86_64 make linux

# Override mimalloc version if needed
MIMALLOC_VERSION=3.0.10 make linux
```

Before running `make linux`, ensure the Swift Static Linux SDK is installed/configured in your Swift toolchain.

## Quick Start

Pipe any list to `fltr`:

```bash
ls | fltr
```

Type to filter, use arrows to navigate, press Enter to select.

## Features

- **Real-time fuzzy search** - Start typing to filter instantly
- **Streaming input** - UI renders while input is still being read
- **Multi-select** - Pick multiple items with Tab (`-m` flag)
- **Preview windows** - See file contents as you browse
- **FuzzyMatch-powered scoring** - Uses [ordo-one/FuzzyMatch](https://github.com/ordo-one/FuzzyMatch) (Smith-Waterman)
- **Unicode support** - Handles emoji/CJK rendering and keeps IME candidate UI anchored to the input caret

## Usage Examples

### Basic filtering

```bash
# Filter files
find . -type f | fltr

# Search processes
ps aux | fltr

# Filter environment variables
env | fltr
```

### Multi-select mode

```bash
# Select multiple files
ls -la | fltr --multi
# Use Tab to select, Enter to confirm
```

### Preview files

Preview starts hidden. Press **Ctrl-O** to toggle it on/off.

```bash
# Show file contents (split view) — press Ctrl-O to open
find . -type f | fltr --preview 'cat {}'

# With syntax highlighting
find . -type f | fltr --preview 'bat --color=always {}'

# Floating preview window
find . -type f | fltr --preview-float 'head -30 {}'

# Set a default preview command via env (same toggle behaviour)
export FLTR_PREVIEW_COMMAND='bat --color=always {}'
find . -type f | fltr   # Ctrl-O opens the preview
```

### Limit height

```bash
# Show only 10 lines
ls | fltr --height 10
```

## Key Bindings

| Key | Action |
|-----|--------|
| Type | Filter items |
| `↑` `↓` | Navigate results (one line) |
| `Ctrl-V` | Page down (Emacs-style) |
| `Alt-V` | Page up (Emacs-style) |
| `Enter` | Select and exit |
| `Tab` | Toggle selection (multi-select mode) |
| `Esc` / `Ctrl-C` | Cancel |
| `Ctrl-O` | Toggle preview |
| `Ctrl-A` / `Ctrl-E` | Jump to start/end of input |
| `Ctrl-U` | Clear input |

## Options

```bash
fltr [OPTIONS]

  -h, --height <N>          Limit display height
  -m, --multi               Enable multi-select mode
  --case-sensitive          Case-sensitive matching
  --preview <command>       Show preview (split view, toggle with Ctrl-O)
  --preview-float <command> Show preview (floating window, toggle with Ctrl-O)
  --help                    Show help

Environment variables:
  FLTR_PREVIEW_COMMAND      Default preview command when --preview / --preview-float are not given
```

In preview commands, use `{}` as a placeholder for the selected item:
- `cat {}` - File contents
- `git log -- {}` - Git history
- `file {}` - File type info

## Tips

**Streaming large datasets:**
```bash
find / -type f 2>/dev/null | fltr
# Renders while stdin continues loading in the background
```

**Whitespace behavior:**
```bash
# Query semantics are delegated to FuzzyMatch.
# Space-separated terms are not treated as a guaranteed AND by fltr itself.
find . -type f | fltr
```

**Case-sensitive search:**
```bash
cat words.txt | fltr --case-sensitive
```

## Requirements

- macOS 26+
- Linux support: `glibc` and `musl` (via Swift Static Linux SDK)
- Terminal with ANSI color support

## Development

**Build:**
```bash
swift build
```

**Run tests:**
```bash
swift test
```

**Architecture:**

Built with Swift 6.3 using:
- Actors for safe concurrency
- Parallel matching across CPU cores
- [FuzzyMatch](https://github.com/ordo-one/FuzzyMatch) Smith-Waterman scoring
- Byte-level match position recovery for ranking/highlight paths
- Streaming stdin reader
- Incremental filtering for fast typing

See `AGENTS.md` for detailed architecture documentation.

## License

MIT License - See LICENSE file for details.

Inspired by [fzf](https://github.com/junegunn/fzf) and [skim](https://github.com/lotabout/skim).
