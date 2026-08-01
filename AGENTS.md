# AGENTS.md

## Purpose

`fltr` is a fast, cross-platform fuzzy finder CLI. Preserve its interactive behavior, streaming design, Unicode correctness, and low-allocation matching path unless the task explicitly changes one of those contracts.

This file contains durable repository guidance. Keep task-specific requirements in the task prompt, state each rule once, and add nested `AGENTS.md` files only when a subtree needs genuinely different instructions.

## Working Contract

- Start from the requested outcome and inspect the relevant code, tests, and documentation before editing.
- For requests to explain, review, diagnose, or plan, inspect and report; do not modify files unless the request also asks for changes.
- For requests to change, build, or fix, make the in-scope local changes and run relevant non-destructive validation without asking first.
- Ask before destructive actions, external writes, adding production dependencies, changing public behavior beyond the request, or materially expanding scope.
- If an ambiguity would materially change behavior, architecture, compatibility, or the public API, ask. Otherwise make the smallest reasonable assumption and proceed.
- Preserve unrelated user changes. Never discard or rewrite work that is outside the task.
- Do not weaken tests, remove required behavior, or bypass correctness checks merely to make a build pass.
- Do not claim completion without validation evidence. Report any check that could not be run and why.

## Repository Rules

- Use the Swift version selected by `.swift-version`; the package manifest currently uses Swift tools 6.2 and strict Swift 6 concurrency.
- Check `swift --version` before validation. If the active compiler does not match `.swift-version` and Swiftly is installed, run Swift commands through `swiftly run swift ...`.
- Support macOS 26+ and Linux. Keep POSIX and terminal code portable across Darwin, glibc, and musl where applicable.
- Make a focused git commit for each meaningful change.
- Do not push, open a pull request, tag, or publish a release unless the user requests it.
- Version tags never use a `v` prefix.
- Never use `swift-actions/setup-swift@v2` in GitHub Actions.

## Definition of Done

Before finishing a change:

1. Preserve existing functionality, CLI contracts, output, and user-visible behavior outside the requested scope.
2. Add or update tests for changed behavior and important edge cases.
3. Run the narrowest relevant checks, then the broader suite when the change can affect shared behavior.
4. For performance-sensitive work, run the required before/after benchmark with the same release configuration and report the observed deltas.
5. Review the final diff for accidental edits, stale comments, platform assumptions, and user-specific paths.
6. Commit the completed change with a concise message.
7. Summarize the outcome first, followed by validation performed and any remaining risk or unverified check.

## Build and Test Commands

Run commands from the repository root unless noted otherwise.

```bash
# Debug build and full test suite
swift build
swift test

# Targeted tests
swift test --filter <TestName>

# Optimized host build with mmap-backed TextBuffer
make release

# Linux static build; requires the Swift Static Linux SDK
make linux

# Non-core packages
swift build --package-path Examples
swift build -c release --package-path Benchmarks --product matcher-benchmark
```

Use `--package-path` for the `Examples` and `Benchmarks` packages. Do not assume building the root package covers them.

### Validation by Change Type

| Change | Minimum validation |
| --- | --- |
| Documentation only | Review the rendered Markdown, commands, links, and final diff |
| Matcher, engine, storage, or shared library | Relevant targeted tests, then `swift test` |
| CLI arguments or output | `swift test` plus a representative non-interactive invocation |
| TUI input, rendering, preview, or terminal behavior | Relevant UI tests, `swift test`, and a TTY smoke check when available |
| Package or build configuration | `swift build` and `swift test`; build affected secondary packages |
| Linux, POSIX, or C shims | `swift test` plus `make linux` when the SDK is available |
| Matching or rendering performance | Tests plus the mandatory benchmark below |

## Performance Gate

Matcher, engine, storage hot-path, result-merging, or highlight changes require a controlled release benchmark. The current `matcher-benchmark` harness uses a fixed dataset and iteration count; it does not parse command-line tuning flags. Run it repeatedly on the same machine and release build before and after the change.

```bash
swift build -c release --package-path Benchmarks --product matcher-benchmark
BENCH_BIN="$(swift build -c release --package-path Benchmarks --show-bin-path)/matcher-benchmark"

for run in {1..5}; do
  "$BENCH_BIN"
done | tee /tmp/fltr-bench.before.txt

# Apply the change and rebuild, then run the same command to:
# /tmp/fltr-bench.after.txt

diff -u /tmp/fltr-bench.before.txt /tmp/fltr-bench.after.txt
```

Report the median total time, matches per second, and time per match across the five runs. Do not compare different machines or build configurations. If ranking quality or the comparison harness changes and the external `FuzzyMatch/` comparison checkout is available, also run `scripts/fuzzy_match_benchmark.sh` with identical options before and after.

## Architecture Map

```text
Sources/fltr/                 Executable entry point and CLI wiring
Sources/FltrLib/
  Matcher/                    FuzzyMatch adapter, prepared queries, rank metadata
  Storage/                    TextBuffer, ItemCache, ChunkStore, per-chunk cache
  Engine/                     Parallel matching and lazy result merging
  Reader/                     Streaming stdin ingestion
  UI/                         UIController, input, rendering, highlights, preview
Sources/TUI/                  Reusable terminal primitives and input decoding
Sources/FltrCSystem/          Darwin/Linux POSIX shims
Tests/fltrTests/              Root package tests
Examples/                     Separate examples package
Benchmarks/                   Separate benchmark package
```

Main data flow:

```text
stdin -> StdinReader -> TextBuffer + ItemCache
      -> MatchingEngine -> ResultMerger
      -> UIController -> UIRenderer + PreviewState -> Terminal
```

Key ownership boundaries:

- `ItemCache`, `RawTerminal`, and `UIController` are actors.
- `MatchingEngine` uses task groups only above its parallel threshold.
- `TextBuffer` protects shared bytes with a read-write lock; its `nonisolated` access depends on that synchronization and single-reference ownership model.
- `ChunkStore` has one writer under `ItemCache`; snapshots share sealed chunks by copy-on-write and copy only the tail.
- `ChunkCache` uses `Mutex` for access from matching partitions.
- Preview task lifecycle and all mutable UI state remain isolated to `UIController`.

## Behavioral and Performance Invariants

- Query parsing and match semantics are delegated to the FuzzyMatch-backed matcher. Do not describe space-separated queries as guaranteed AND behavior unless the implementation and tests establish it.
- Keep `Item` at 12 bytes (`Int32` index plus `UInt32` offset and length). Do not store a `String` or `TextBuffer` reference per item.
- Keep matching on UTF-8 byte windows. Construct `String` values only on cold paths such as rendering, final output, and preview commands.
- Preserve rank-only matching on the hot path and compute full highlight positions only for visible or explicitly emitted rows.
- Preserve the zero-allocation empty-query path and lazy global materialization in `ResultMerger`.
- Preserve incremental filtering as lossless: extending a query may narrow the candidate set, but results must not be silently capped.
- Keep chunk snapshots cheap. Avoid changes that copy the complete item set while stdin is streaming.
- Keep preview opt-in. Do not spawn a preview subprocess while the preview pane is hidden.
- Maintain grapheme-safe input editing, correct display-width rendering for emoji/CJK, and terminal cursor anchoring at the input caret for IME candidate placement.
- Treat byte offsets, Unicode scalar or grapheme indices, and terminal display columns as different coordinate systems; convert deliberately and test mixed-width text.
- Preserve terminal cleanup and cancellation behavior on success, error, Ctrl-C, and escape paths.

## Implementation Guidance

- Prefer small, behavior-preserving changes over broad rewrites.
- Follow existing Swift 6 concurrency patterns. Make isolation and `Sendable` requirements explicit; do not add `@unchecked Sendable` without a documented synchronization invariant.
- Reuse prepared matcher state and scratch buffers in hot loops. Avoid per-item allocation, repeated query parsing, eager full-result sorting, or eager highlight calculation.
- Keep UI event parsing, state mutation, action handling, and rendering responsibilities separated along the existing component boundaries.
- Add dependencies only when the standard library and existing packages cannot reasonably solve the problem, and obtain approval first.
- Comments should explain invariants, ownership, non-obvious platform behavior, or performance reasoning rather than restating code.
- Update user-facing documentation when flags, key bindings, environment variables, platform requirements, or observable behavior change.

## Code Review Rules

Prioritize actionable correctness and regression risks:

- Flag actor-isolation violations, unsafe shared mutable state, incomplete cancellation, or lock lifetime errors. Give the safe isolation or ownership path.
- Flag confusion between UTF-8 byte offsets, Swift character indices, and terminal display columns. Require coverage with combining marks, emoji, and CJK when relevant.
- Flag hot-path allocations, eager materialization, full-set copying, or repeated matcher setup that can regress large-input latency or RSS. Require benchmark evidence for intentional tradeoffs.
- Flag Darwin-only APIs or assumptions in shared code. Route platform differences through `FltrCSystem` or guarded implementations.
- Flag changes that alter query ranking, selection order, preview execution, terminal restoration, or CLI output without explicit tests and documentation.
- Reserve formatting-only concerns for automated tooling; review comments should identify a concrete failure mode and a safe correction.

## Useful Utilities

```bash
# Profile a representative run
make profile INPUT=./input.txt ARGS="--query foo"

# Compare FuzzyMatch and fltr throughput; requires ./FuzzyMatch checkout
scripts/fuzzy_match_benchmark.sh --iterations 5 --fm-mode ed
scripts/fuzzy_match_benchmark.sh --iterations 5 --fm-mode both
```

See `README.md` for user-facing behavior and installation, and `Documents/FUZZY_MATCH_COMPARISON.md` for matcher comparison details.
