# Chat performance verification

## Synchronous model benchmarks

Measured on 2026-11-06 using Apple M4 Pro, macOS 26.6.2 (25G83), and Apple Swift 6.3.3. Both variants use Release optimization (`-O`, without `DEBUG`). Baseline and final measurements ran sequentially after native window stress and other builds stopped. All six benchmark tests passed for each variant.

These samples measure synchronous main-actor elapsed work. They do not measure keyboard-to-paint latency, SwiftUI layout, scroll frame rate, or end-to-end bot responses.

| Operation | 1k baseline p95 ms | 1k final p95 ms | 10k baseline p95 ms | 10k final p95 ms |
| --- | ---: | ---: | ---: | ---: |
| Bot draft setter + cached presentation | 0.409750 | 0.002833 | 0.372417 | 0.003000 |
| Bot metadata event + presentation | 1.026750 | 0.001542 | 9.925500 | 0.001542 |
| Bot sequential stream delta + presentation | 1.031292 | 0.038125 | 10.238583 | 0.302583 |
| Room draft setter + cached presentation | 0.000709 | 0.000750 | 0.000708 | 0.000750 |
| Room append + explicit snapshot construction | 0.512583 | 0.446583 | 4.852166 | 4.111500 |

Bot and room draft edits each produced **0 parent-model publications for 31 measured edits**, compared with 31 publications in the baseline. The room setter itself was already inexpensive; the useful change is that typing no longer invalidates the parent transcript model. A separate, explicitly manual replay of the old room projection recipe ran 31 times in the baseline and zero times in the final version. That replay is a model control, not a measurement of actual SwiftUI body scheduling.

The bot draft sample measures the immediate setter. Final persistence is debounced, so its later write is outside that sample; the test verifies that closing flushes the final draft correctly. The unchanged direct draft-store control had p95 0.362792 ms baseline and 0.333000 ms final. The result establishes reduced synchronous input-path work, not elimination of persistence cost.

Room snapshot construction remains proportional to history size. Its 10k median was 3.377833 ms baseline and 3.557208 ms final (+5.3%), while p95 was lower in the final run. This does not establish a general room-append speedup. The fixture reuses early thread anchors; many recent anchors may have different costs. These short local runs have no confidence intervals or machine-independent performance threshold.

## Native rendering and interaction verification

The selected renderer is a single-column `NSTableView` with reusable SwiftUI hosting cells for Bot Chat,
Group Chat, and thread panes. The native coordinator owns follow intent, row jumps and viewport anchors.
There is no lazy/eager message split or second SwiftUI size anchor changing the offset. Height estimates
do not construct offscreen rows; the height cache retains at most 4,096 entries. A text delta remeasures
the changed visible row rather than all visible history. Long Markdown parsing uses one active CPU job
and a responsive scheduler capped at eight pending clients / 8 MiB of pending UTF-8 source.

Final headless verification: 1,422 XCTest cases discovered, 55 opt-in/window cases skipped, 1,367 passed;
37 Swift Testing cases also passed. There were no failures. The full run took about 91 seconds.
The focused controller/parser/composer/incremental pass also passed all 36 cases after the final
short-transcript fixes, including erased UUID search jumps and a paused short reply growing long.

The selected native-window/layout pass completed 26 cases without failures. It covers 600-message Bot
and Group Chat histories, appended replies while reading, unread and jump-to-latest behavior, sidebar
and inspector widths, native editor identity/selection during streaming, and tall replies containing
24 sections, a 50-row table and an 80-line code block. The viewport is sampled during wheel steps;
tests assert that the reusable cell pool stays below 160 for these fixtures. Short-content alignment,
deleted-anchor recovery and follow after short-to-long growth have additional headless native-table
regressions. Native runs use fakes and send nothing to Hermes.

Visibility checks composite the complete hosting window before cropping the transcript interior.
Caching a tall hosting cell through its scroll view produced false blank detections despite visible
text in the full-window image. The crop excludes sidebar, status ribbon, composer, scrollers and jump
overlay. Its negative control keeps bright surrounding chrome while the transcript region is blank.
AX presence alone is not accepted as proof of drawn content.

The packaged Release app was also checked with an existing long Bot Chat and a five-member room on the
local backend: scrolling, sidebar reflow, returning to latest, and temporary draft entry/clear were
observed. No test message was sent; the room sequence remained unchanged. GUI automation transport
timeouts were excluded from performance conclusions.

These checks are correctness and bounded-work evidence. They do not establish a frame-rate target or
keyboard-to-paint percentile. Canonical history remains fully loaded; view virtualization does not
provide data pagination or a fixed total-memory ceiling. A single extremely large row still incurs
native text/table layout work; block-level segmentation remains conditional on further profiling.

## Fixtures and reproduction

The exact same [benchmark source](../Tests/HermesBotAppTests/TranscriptPerformanceBenchmarks.swift) was used for both snapshots (SHA-256 `84c1579352070309563fff1321defd3b3295451623a16b08b8e7944943cbbb58`). Each fixture has 1,000 or 10,000 input history records/events, mixing user replies, assistant replies, tools, reasoning, and thread activity. Some retained assistant replies contain 80 Markdown sections with wrapped prose and tables. Streaming applies 64 sequential chunks, each approximately 0.5 KB. A real isolated `UserDefaults` draft store starts with 64 drafts of approximately 4 KB each. Fake chat/room services are used; the benchmarks do not connect to Hermes or send bot messages.

Fixtures, initial projections, persistence setup, and cleanup are outside the sampled work. Most operations use 31 samples after three warmups; streaming uses 64 consecutive samples without warmups. p95 uses the nearest-rank sample. The room append sample explicitly constructs a presentation from the public timeline; it does not invoke the private room-model poll-update method.

The baseline is a frozen pre-optimization working tree, not a released version or clean Git revision. Its temporary manifest selects the benchmark and native-window test helpers because an existing test referenced a production-excluded `DEBUG` hook. Its original manifest was preserved. The final snapshot uses the **unchanged full project manifest** after that test was correctly guarded by `#if DEBUG`; all Release test targets compiled successfully. Repository HEAD at final capture was `a5730afafbcb4e7e0da72f04a26dd2aa6fa8c6dc`, with the uncommitted implementation included in the frozen source snapshot.

Run the current benchmark from the repository root:

```sh
CI=false HERMES_BOT_APP_WINDOW_TESTS=0 \
HERMES_TRANSCRIPT_BENCHMARKS=1 HERMES_PERF_LABEL=current \
HERMES_PERF_REPORT_PATH=/tmp/herald-performance-current.jsonl \
swift test -c release --jobs 2 --filter TranscriptPerformanceBenchmarks
```

Use a new report path for each run: results append as JSONL. `HERMES_PERF_SAMPLES` optionally changes the default 31 samples (range 5–101). Compare the same source file, fixture, build configuration, and sample count, and stop native stress/builds during measurement. No windows are opened by this benchmark.

Local verification artifacts:

- Baseline source: `/tmp/herald-perf-baseline.RK2DLV`; build: `/tmp/herald-perf-baseline-build`.
- Final source: `/tmp/herald-perf-final.sld8_wba`; build: `/tmp/herald-perf-final-build`.
- Raw final comparison: `/tmp/herald-perf-baseline-final.jsonl` and `/tmp/herald-perf-current-final.jsonl`.
- Test logs: `/tmp/herald-perf-baseline-final.log` and `/tmp/herald-perf-current-final.log`.

To replay those frozen artifacts, run the same command in each source directory with `--skip-build --scratch-path <matching-build-path>`, choosing separate labels and output paths. Temporary artifacts may be cleaned up; they are not committed benchmark fixtures.
