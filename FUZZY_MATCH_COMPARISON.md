# FuzzyMatch vs fltr Comparison (macOS arm64)

## Scope

This comparison uses the same corpus and query set from `FuzzyMatch/Resources`:

- Corpus: `instruments-export.tsv` (271,625 candidates)
- Queries: `queries.tsv` (197 queries)

Throughput and quality were measured for:

- **FuzzyMatch (Edit Distance)** via `FuzzyMatch/Comparison/run-benchmarks.sh --fm-ed`
- **fltr** via new harnesses added in this repo:
  - `comparison-bench-fltr` (throughput)
  - `comparison-quality-fltr` (quality)

## Throughput

### Commands

```bash
# FuzzyMatch ED throughput
bash FuzzyMatch/Comparison/run-benchmarks.sh --fm-ed --iterations 5

# fltr throughput
swift run -c release --package-path Benchmarks comparison-bench-fltr \
  --tsv FuzzyMatch/Resources/instruments-export.tsv \
  --queries FuzzyMatch/Resources/queries.tsv \
  --iterations 5
```

### Results

| Tool | Median total time (197 queries) | Throughput (median) | Per-query average |
|---|---:|---:|---:|
| FuzzyMatch (ED) | 3134.0 ms | 17M candidates/sec | 15.91 ms |
| fltr (Utf8FuzzyMatch harness) | 2571.8 ms | 21M candidates/sec | 13.06 ms |

Relative throughput:

- `fltr` is about **1.24x faster** than FuzzyMatch(ED) on this run (`21M / 17M`).
- Median total time improved by about **18.0%** (`3134.0ms -> 2571.8ms`).

## Filtering Quality

### Commands

```bash
# Build FuzzyMatch quality harness
(cd FuzzyMatch/Comparison/quality-fuzzymatch && swift build -c release)

# Prepare stdin query stream (query + field)
awk -F'\t' '{print $1"\t"$2}' FuzzyMatch/Resources/queries.tsv > /tmp/quality-queries-input.tsv

# Run quality outputs
cat /tmp/quality-queries-input.tsv \
  | FuzzyMatch/Comparison/quality-fuzzymatch/.build/arm64-apple-macosx/release/quality-fuzzymatch \
    FuzzyMatch/Resources/instruments-export.tsv \
  > /tmp/quality-fuzzymatch-ed.tsv

cat /tmp/quality-queries-input.tsv \
  | swift run -c release --package-path Benchmarks comparison-quality-fltr FuzzyMatch/Resources/instruments-export.tsv \
  > /tmp/quality-fltr.tsv
```

Ground-truth evaluation follows `FuzzyMatch/Comparison/run-quality.py` logic:

- Categories `typo`, `prefix`, `abbreviation`: expected name can appear in **top-5**
- Other categories: expected name must appear in **top-1**
- Match is case-insensitive substring match against result name

### Results

Coverage:

- FuzzyMatch(ED): results for **197/197** queries
- fltr harness: results for **190/197** queries

Ground-truth hits (evaluated queries with expected answer: 152):

- FuzzyMatch(ED): **150/152 (98.7%)**
- fltr harness: **128/152 (84.2%)**

Top-1 agreement between FuzzyMatch(ED) and fltr:

- **147/197 (74.6%)**

Per-category ground-truth highlights:

| Category | FuzzyMatch(ED) | fltr |
|---|---:|---:|
| exact_name | 35/35 | 34/35 |
| exact_isin | 6/6 | 6/6 |
| prefix (top-5) | 21/21 | 21/21 |
| typo (top-5) | 41/41 | 24/41 |
| substring | 22/22 | 22/22 |
| multi_word | 15/15 | 15/15 |
| abbreviation (top-5) | 10/12 | 6/12 |

## Interpretation

- On this corpus, the `fltr` matcher path used in this harness is **faster** than FuzzyMatch(ED).
- FuzzyMatch(ED) has **better typo and abbreviation quality**, which dominates its ground-truth lead.
- `fltr` is strong on exact/prefix/substring/multi-word, but loses quality on typo-heavy queries.

## Notes on Fairness

- Both throughput harnesses include top-K heap maintenance (K=100) and per-query preparation inside timed loops.
- Current `fltr` quality harness uses public `Utf8FuzzyMatch` token-AND scoring with score/length/index ranking.
- This is close to `fltr` internals but not a full UI/controller path benchmark.

## How to Add fltr to FuzzyMatch Comparison Suite

To integrate directly into `FuzzyMatch/Comparison/run-benchmarks.sh` and `run-quality.py`:

1. Add a `bench-fltr` harness under `FuzzyMatch/Comparison/` that shells out to this repo's `comparison-bench-fltr` (or vendors equivalent code).
2. Add `--fltr` flag handling in `run-benchmarks.sh`.
3. Save output to `/tmp/bench-fltr-latest.txt` and include it in AWK table columns.
4. Add `quality-fltr` invocation in `run-quality.py` and include it in agreement/ground-truth tables.

The two executables added in this repo are intended to be reused for that integration.
