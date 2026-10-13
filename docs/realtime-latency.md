# Native realtime preview latency

Measured on this Mac on 2026-10-13: Apple Silicon, hardware identifier `Mac15,12`, 16 GiB memory, Version 27.2 (Build 26B5086k), TeX Live 2026 and the pinned realtime-tex v0.0.10 engine. The app and harness use release optimization.

The benchmark instantiates the production `MainWindowController` and `EditorViewController`, inserts text through `NSTextView.insertText`, and stops the clock when the visible native PDFKit overlay finishes drawing. Thus it includes editor callbacks, UTF-8 diff, process transport, Rust/LuaTeX, display-list preparation, main-thread delivery, and CoreText/CoreGraphics drawing. It excludes physical keyboard sampling and compositor/display scan-out. Each case waits for the live-engine Ready signal and records 40 insertions after five warm-ups. The generated documents contain text and inline math, with explicit page breaks; they are controlled fixtures, not a universal bound for arbitrary TeX.

| Fixture | Initial source bytes | Median ms | p95 ms | Maximum ms |
| --- | ---: | ---: | ---: | ---: |
| OpenType + math, 10 pages | 8,504 | 2.80 | 6.83 | 17.10 |
| Type 1 + math, 10 pages | 8,550 | 2.11 | 9.70 | 11.52 |
| OpenType + math, 100 pages | 88,155 | 12.01 | 13.55 | 16.16 |
| OpenType + math, 300 pages | 265,355 | 11.75 | 13.46 | 13.85 |

These measurements are from build 8. All recorded warm p95 values are below 50 ms; the maximum across these samples was 17.10 ms. The p95 result is not a per-edit upper bound. Raw samples are in [realtime-latency-results.json](realtime-latency-results.json). Reproduce with `./scripts/test-realtime-latency.sh` after building the app. Timing varies with document, system load, fonts and hardware; initial engine/font loading is excluded.

## Engine v0.0.10 and native page progress (build 8)

The bundle now uses the verified v0.0.10 release at `83466a1c1293a5b1525f8bcc53c4ea95130dca5a`, with the Rust host and matching Lua resources packaged together. This includes reusable new-paragraph contexts after headings/environments and complete early `PagePreview` / `PagePreviewReset` events. Building downloads the release archive instead of compiling Rust.

A native integration fixture grows a paragraph across pages while its suffix spends one second in Lua. Its first complete page visibly paints in 104.03 ms, 1076.15 ms before the whole PDF arrives. The drawing matches the final PDF at 99.995% / 99.974% within one pixel. A subsequent growing edit remains visible in 9.67 ms, and a failed suffix rolls back provisional pages with diagnostics preserved. These page-progress timings describe this controlled fixture, not a 50 ms guarantee for document-wide reflow. Raw data: [page preview](realtime-page-preview-results.json).

A complete provisional page is accepted only if all of its resources and operations can be drawn. Per-page source revisions suppress live boxes already present in that page. Source mapping follows the displayed placements. An older page snapshot is deferred if it would hide a newer growing box; growth after an accepted snapshot restores the committed baseline and continues immediate live drawing while pagination catches up. Reset events restore the baseline and newer live boxes. Full layouts clear every provisional page before applying sparse deltas. The host retains unplaced new boxes for later anchors, and avoids redrawing visible pages for unrelated off-screen page updates.

The 100-page fixture painted all 60 revisions at p95 15.81 ms. The original 444,260-byte, 112-page physics notes painted all 60 unsaved typing revisions at p95 19.25 ms; its split paragraph painted before a replacement PDF and the source stayed unchanged. The harness counts compatible complete-page paints as well as paragraph paints. Raw samples: [physics notes](realtime-live-edit-physics-results.json), [100-page fixture](realtime-live-edit-results.json). Autosave is delayed during this test and no full PDF is requested per edit. These timings exclude display scan-out.

## What changed

The PDF-only version delayed layout requests by 350 ms and waited for an entire background PDF. A simple local probe measured roughly 413 ms for that background pass itself. The new visible fast path bypasses both waits: it draws the edited unit immediately from the persistent engine's `ParagraphUpdate`, using PDFKit's native page overlays and the actual TeX font files through CoreText. It masks the old unit's rows and draws glyphs, rules, colors, supported images and native paths at the engine's exact positions. Font/encoding caches are warmed when the first full layout arrives. Per-keystroke span-list requests were removed, UTF-8 diffing avoids arrays of Unicode scalars, and native drawing operations are indexed by item rather than repeatedly scanned.

Build 7 removes the host’s unconditional 350 ms full-layout timer. The engine itself requests reflow for changes affecting pagination, counters and references. Background snapshots advance while typing; newer live events are reanchored and retained until their source revision is captured, retaining page and zoom. Search/selection uses that PDF's text until it is replaced. Cold resources, unverified units, variable font axes, rotated/cropped embedded PDFs, gradients, patterns/fadings and unhandled operations keep their last complete drawing until the PDF arrives; they do not have the above fast-path guarantee.

## Drawing verification

`./scripts/test-realtime-fidelity.sh` compares the provisional native drawing against the subsequent shipped PDF, rasterized through PDFKit at 1200 × 1600. It requires at least 99% ink/color correspondence in both directions within one pixel, allowing rasterizer edge anti-aliasing differences. Cases cover OpenType colored text and fraction math, encoded Type 1 text/math, a TikZ path with CMYK fill and a label, and an asymmetric four-color image. The raw results are in [realtime-fidelity-results.json](realtime-fidelity-results.json); PNG pairs are saved under `.build/realtime-fidelity/` for inspection.

`./scripts/test-realtime-native.sh` separately checks complete PDF replacement, unsaved root/included-file edits, invalid-PDF retention, page/zoom preservation, shrinking documents and native toolbar actions. `xcrun --toolchain default swift test` includes UTF-8 scalar-boundary and Unicode-normalization regression cases.

The 43-check build 8 audit (`./scripts/test-realtime-audit.sh`) covers renderer fallback, removed-unit masks, nested color-stack restoration, missing-font lookup caching and retry, byte-exact Unicode reloads, navigation bounds, autosave/shutdown behavior, preview-layer ordering/rollback, interrupted-log cache restoration, and actual LuaLaTeX process cleanup. The native integration test also requires independent rapid root/included-file edits to reach the fast path and verifies safe fallback after source deletion and release of the retained startup-cache lease.

## Cached startup with v0.0.10 (build 8)

The production window opened the unchanged 112-page notes in 3.608 seconds, with engine Ready at 3.609 seconds. Reopening measured 3.368 / 3.374 seconds. Native cursor-follow tests passed on the three-page fixture and its reopened window. Cache sealing also rejects a log newer than its completed source marker, so an interrupted pass cannot pair stale PDF/capture data with a new incomplete log. Raw startup data: [build 8](realtime-startup-build8-results.json).

## Startup and cursor following (build 6)

The startup audit found a 13.8 MB layout message from the physics notes. The previous reader rescanned its accumulated Data on every 4 KiB chunk; the isolated framing benchmark exceeded 60 seconds before completing the message. The new reader scans only incoming bytes and framed the entire message in 5.2 ms. This measures framing alone, excluding JSON decoding, native resource preparation, and PDFKit loading.

A persistent cache now preserves complete, source-hashed capture/PDF pairs outside the engine’s two mutable pass slots. This protects startup after the app closes during an unfinished background pass. Reopening restores the completed snapshot before launching the engine; the library checks its source hash, and a new full pass reconciles the document. Concurrent sessions use isolated temporary builds.

Using a validated cache from the read-only engine baseline, the production window loaded the 112-page notes in 4.088 seconds and delivered the engine Ready signal in 4.090 seconds. Reopening measured 3.477 and 3.479 seconds respectively. Source files were unchanged. The cold engine-only baseline reached Ready in 3.819 seconds and its first provisional 110-page layout in 51.846 seconds; full TikZ typesetting remains more expensive than cache restoration. These measurements describe this project and machine, not a universal startup limit. Raw data is in [realtime-startup-results.json](realtime-startup-results.json).

Follow cursor ports the plugin’s UTF-8 span lookup and proportional row/fragment targeting into Swift. Native selection notifications debounce for 150 ms, refresh invalidated span metadata on demand, and follow live fragment placements. PDFKit scrolls an out-of-view target about 35% down the viewport, leaves visible targets alone, preserves editor focus, and adds a marker only for forced navigation. The native checkbox disables automatic movement while manual `⌘J` remains available.

The long-document typing regression also checks that a stale background pass cannot clear a newer live edit. The engine reports the current session source revision in these events; build 7 derives the captured revision from `Stale.pending_since - 1`, accepts that pagination progress and replays only newer live events against its placements. Newly created units do not require an old PDF mask. Build 7 bundled upstream commit `273f8cc`, including continuous-layout and prioritized-reflow fixes; both Rust and Lua files come from the same verified archive.
