# FuzzyMatch vs fltr Comparison (macOS arm64)

## Scope

This comparison uses the same corpus and query set from `FuzzyMatch/Resources`:

- Corpus: `instruments-export.tsv` (271,625 candidates)
- Queries: `queries.tsv` (197 queries)

Throughput and quality were measured for:

- **fltr**
- **FuzzyMatch (Edit Distance)** (`FuzzyMatch(ED)`)
- **FuzzyMatch (Smith-Waterman)** (`FuzzyMatch(SW)`)
- **nucleo**

## Throughput

### Commands

```bash
# 4-tool throughput + quality comparison
scripts/fuzzy_match_benchmark.sh --fm-mode both
```

### Results

| Tool | Median total time (197 queries) | Throughput (median) | Per-query average | vs fltr |
|---|---:|---:|---:|---:|
| fltr | 2436.7 ms | 22M candidates/sec | 12.37 ms | - |
| FuzzyMatch(ED) | 2902.5 ms | 18M candidates/sec | 14.73 ms | 0.84x |
| FuzzyMatch(SW) | 1505.2 ms | 36M candidates/sec | 7.64 ms | 1.62x |
| nucleo | 870.4 ms | 61M candidates/sec | 4.42 ms | 2.80x |

Relative throughput:

- `FuzzyMatch(ED)` is slower than `fltr` in this run (`0.84x` vs fltr).
- `FuzzyMatch(SW)` and `nucleo` are faster than `fltr` (`1.62x`, `2.80x` vs fltr).

## Filtering Quality

### Commands

```bash
# Quality-only run
scripts/fuzzy_match_benchmark.sh --no-throughput --fm-mode both
```

Ground-truth evaluation follows `FuzzyMatch/Comparison/run-quality.py` logic:

- Categories `typo`, `prefix`, `abbreviation`: expected name can appear in **top-5**
- Other categories: expected name must appear in **top-1**
- Match is case-insensitive substring match against result name

### Results

Coverage:

- fltr: results for **190/197** queries
- FuzzyMatch(ED): results for **197/197** queries
- FuzzyMatch(SW): results for **187/197** queries
- nucleo: results for **190/197** queries

Ground-truth hits (evaluated queries with expected answer: 152):

- fltr: **128/152 (84.2%)**
- FuzzyMatch(ED): **150/152 (98.7%)**
- FuzzyMatch(SW): **129/152 (84.9%)**
- nucleo: **121/152 (79.6%)**

Top-1 agreement between FuzzyMatch(ED) and fltr:

- **147/197 (74.6%)**

Per-category ground-truth highlights:

| Tool | Results | GT hits | GT % |
|---|---:|---:|---:|
| fltr | 190/197 | 128/152 | 84.2% |
| FuzzyMatch(ED) | 197/197 | 150/152 | 98.7% |
| FuzzyMatch(SW) | 187/197 | 129/152 | 84.9% |
| nucleo | 190/197 | 121/152 | 79.6% |

## Interpretation

- On this run, `fltr` is faster than `FuzzyMatch(ED)` but slower than `FuzzyMatch(SW)` and `nucleo`.
- `FuzzyMatch(ED)` has the strongest overall quality on this dataset.
- `fltr` and `FuzzyMatch(SW)` are close in aggregate GT hit rate (84.2% vs 84.9%).

## Notes on Fairness

- Both throughput harnesses include top-K heap maintenance (K=100) and per-query preparation inside timed loops.
- Current `fltr` quality harness uses the public `FuzzyMatcher` ranking path in `Benchmarks`.
- This is close to `fltr` internals but not a full UI/controller path benchmark.

## How to Add fltr to FuzzyMatch Comparison Suite

To integrate directly into `FuzzyMatch/Comparison/run-benchmarks.sh` and `run-quality.py`:

1. Add a `bench-fltr` harness under `FuzzyMatch/Comparison/` that shells out to this repo's `comparison-bench-fltr` (or vendors equivalent code).
2. Add `--fltr` flag handling in `run-benchmarks.sh`.
3. Save output to `/tmp/bench-fltr-latest.txt` and include it in AWK table columns.
4. Add `quality-fltr` invocation in `run-quality.py` and include it in agreement/ground-truth tables.

The two executables added in this repo are intended to be reused for that integration.
