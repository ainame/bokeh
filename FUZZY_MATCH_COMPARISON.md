# FuzzyMatch vs fltr Comparison (macOS arm64)

## Scope

This comparison uses the same corpus and query set from `FuzzyMatch/Resources`:

- Corpus: `instruments-export.tsv` (271,625 candidates)
- Queries: `queries.tsv` (197 queries)

Throughput and quality were measured for:

- **FuzzyMatch (Edit Distance)** (`FuzzyMatch(ED)`)
- **FuzzyMatch (Smith-Waterman)** (`FuzzyMatch(SW)`)
- **fltr** (current benchmark wrapper run used `--fltr-matcher swfast`)
- Reference tools in the same run: `nucleo`, `fzf` (quality only)

## Throughput

### Commands

```bash
# End-to-end throughput + quality (includes FM ED/SW, fltr, nucleo, fzf)
scripts/fuzzy_match_benchmark.sh --iterations 1 --fm-mode both --fltr-matcher swfast
```

### Results

| Tool | Median total time (197 queries) | Throughput (median) | Per-query average |
|---|---:|---:|---:|
| fltr(swfast) | 4198.0 ms | 13M candidates/sec | 21.31 ms |
| FuzzyMatch (ED) | 3019.8 ms | 18M candidates/sec | 15.33 ms |
| FuzzyMatch (SW) | 1578.8 ms | 34M candidates/sec | 8.01 ms |
| nucleo | 917.9 ms | 58M candidates/sec | 4.66 ms |

Relative throughput:

- `FuzzyMatch(SW)` is about **2.66x faster** than `fltr(swfast)` (`4198.0 / 1578.8`).
- `FuzzyMatch(ED)` is about **1.39x faster** than `fltr(swfast)` (`4198.0 / 3019.8`).
- `nucleo` is fastest in this run at **4.57x** vs `fltr(swfast)` (`4198.0 / 917.9`).

## Filtering Quality

### Commands

```bash
# End-to-end quality (includes FM ED/SW, fltr, nucleo, fzf)
scripts/fuzzy_match_benchmark.sh --no-throughput --fm-mode both --fltr-matcher swfast
```

Ground-truth evaluation follows `FuzzyMatch/Comparison/run-quality.py` logic:

- Categories `typo`, `prefix`, `abbreviation`: expected name can appear in **top-5**
- Other categories: expected name must appear in **top-1**
- Match is case-insensitive substring match against result name

### Results

Coverage:

- fltr(swfast): results for **190/197** queries
- FuzzyMatch(ED): results for **197/197** queries
- FuzzyMatch(SW): results for **187/197** queries
- nucleo: results for **190/197** queries
- fzf: results for **186/197** queries

Ground-truth hits (evaluated queries with expected answer: 152):

- fltr(swfast): **128/152 (84.2%)**
- FuzzyMatch(ED): **150/152 (98.7%)**
- FuzzyMatch(SW): **129/152 (84.9%)**
- nucleo: **121/152 (79.6%)**
- fzf: **126/152 (82.9%)**

Top-1 agreement:

- FuzzyMatch(ED) vs fltr(swfast): **147/197 (74.6%)**
- FuzzyMatch(SW) vs fltr(swfast): **95/197 (48.2%)**

Per-category ground-truth highlights:

| Category | FuzzyMatch(ED) | FuzzyMatch(SW) | fltr(swfast) |
|---|---:|---:|---:|
| exact_name | 35/35 | 35/35 | 34/35 |
| exact_isin | 6/6 | 6/6 | 6/6 |
| prefix (top-5) | 21/21 | 16/21 | 21/21 |
| typo (top-5) | 41/41 | 23/41 | 24/41 |
| substring | 22/22 | 22/22 | 22/22 |
| multi_word | 15/15 | 15/15 | 15/15 |
| abbreviation (top-5) | 10/12 | 12/12 | 6/12 |

## Interpretation

- On this run, `fltr(swfast)` is **slower** than both FuzzyMatch matchers in throughput.
- `FuzzyMatch(SW)` is much faster than `FuzzyMatch(ED)`, but quality differs by category:
  - stronger on abbreviations,
  - weaker on prefix/typo.
- `FuzzyMatch(ED)` remains the strongest overall quality baseline on this dataset.
- `fltr(swfast)` is close to `FuzzyMatch(SW)` in aggregate GT hit rate (84.2% vs 84.9%), but with different failure modes.

## Notes on Fairness

- Both throughput harnesses include top-K heap maintenance (K=100) and per-query preparation inside timed loops.
- Current `fltr` quality harness uses public matcher backend selection (`--matcher utf8|swfast`) with score/length/index ranking.
- This is close to `fltr` internals but not a full UI/controller path benchmark.

## How to Add fltr to FuzzyMatch Comparison Suite

To integrate directly into `FuzzyMatch/Comparison/run-benchmarks.sh` and `run-quality.py`:

1. Add a `bench-fltr` harness under `FuzzyMatch/Comparison/` that shells out to this repo's `comparison-bench-fltr` (or vendors equivalent code).
2. Add `--fltr` flag handling in `run-benchmarks.sh`.
3. Save output to `/tmp/bench-fltr-latest.txt` and include it in AWK table columns.
4. Add `quality-fltr` invocation in `run-quality.py` and include it in agreement/ground-truth tables.

The two executables added in this repo are intended to be reused for that integration.
