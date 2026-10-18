# TexFast Realtime — alternative release

This `realtime-tex` branch integrates [realtime-tex v0.0.11](https://github.com/kenny-21342/realtime-tex/releases/tag/v0.0.11) into the native editor through its persistent `rtex serve` API. The live PDF pane uses **Apple PDFKit**, with native AppKit controls and selectable PDF text.

Download **TexFast-Realtime-v1.2.0-realtime.9-macOS-arm64.zip** from the [alternative release](https://github.com/kenny-21342/texfast/releases/tag/v1.2.0-realtime.9). It contains **TexFast Realtime.app**, with a separate app identifier and settings so it can coexist with TexFast. Its teal document-and-waveform icon distinguishes it from the purple standard app. This Apple Silicon build requires macOS 13+ and **TeX Live 2026** with LuaLaTeX. The engine is bundled; Rust, Node.js, and VS Code are unnecessary to run the app. Building requires Xcode command-line tools. The app is ad-hoc signed, without notarization.

**TexFast Realtime → Check for Engine Updates…** checks the stable releases of `kenny-21342/realtime-tex` on GitHub. The native update window shows the running and bundled engine versions, release notes, and an Install button when an update is available. Downloads match this Mac’s architecture and are checked against GitHub’s SHA-256 asset digest; the executable and complete Lua resources install together under `~/Library/Application Support/com.kenny-lhs.texfast.realtime/Engines/`. The signed app bundle stays intact. Updates take effect after quitting and reopening the app, so open documents retain their current engine and resources. **Use Bundled Engine…** selects the packaged version for the next launch. Startup caches are separate for each engine release; the first opening after an engine upgrade must build its own cache. Checks are manual, and releases outside the bundled engine’s major/minor series require an app update.

Engine v0.0.11 includes upstream fixes for comment eligibility, two-column placements, IEEEtran floats and run-in headings, included-file environments, math alphabets, and diagnostic continuation lines. The native live preview and per-keystroke edit path remain in use.

With **Live Preview while Typing** enabled, edits go directly from the unsaved editor buffer to the persistent engine. Eligible unit updates draw immediately through **CoreText/CoreGraphics overlays managed by PDFKit**, using the actual TeX font files and engine glyph positions. The fast path has no typing debounce. Native support includes static OpenType/TrueType and Type 1 fonts, math, rules, colors, bitmap images, and basic TikZ paths/clips. Unsupported or degraded material retains its last complete drawing until the background PDF arrives.

Startup retains a source-hashed layout and picture cache between sessions. A separate completed snapshot survives interrupted pagination, while a lease isolates simultaneous sessions. Large layout messages are read in one pass instead of repeatedly scanning accumulated data. On the 112-page physics-notes project, the native preview and live-engine Ready callback arrived in **3.61 seconds**, then **3.37 seconds** on reopening with the validated cache. A cold first full layout still took roughly 52 seconds in the engine-only baseline. See [startup measurements](docs/realtime-startup-build8-results.json).

Live editing does not request a full compile after every keystroke or typing pause. New and split paragraphs paint immediately, including units absent from the previous PDF. The engine schedules background reflow when line counts, structure, counters or references require it. Its committed continuous-typing scheduler prioritizes body reflow and catches up without repeated debounce. PDFKit advances pagination as passes arrive, reanchors newer live drawings to the new pages, and discards only edits already captured by that PDF. Included-file and newly inserted-unit placements also participate in native cursor following. The toolbar distinguishes **LIVE** from completed full-layout **CURRENT**.

Engine v0.0.10 adds complete `PagePreview` drawings before a long document's suffix finishes. Native PDFKit overlays display these whole pages with their updated source placements, then reanchor newer live text when its row count fits the coherent page. Older snapshots that would hide newer growing text are deferred. If a live edit outgrows a provisional page, the host restores the committed base and keeps immediate drawing while the engine arranges compatible pagination. Off-page live boxes stay retained until matching anchors arrive. `PagePreviewReset` restores committed pages and placements after a failed/superseded pass; completed layouts clear all provisional page layers before applying their sparse deltas. New paragraphs after headings and block environments become reusable live units. Search/selection continues to use the authoritative PDF until the full layout arrives.

Autosave persists the buffer without requesting another whole PDF; explicit Save and Recompile request a complete pass. Provisional drawing uses the available page anchors, so downstream page breaks and PDF text selection/search settle with the background PDF. Variable fonts, rotated/cropped embedded PDFs, gradients, patterns/fadings, and other unsupported operations use the full PDF path. Clean export uses the final typesetting pass.

On this Mac, the production editor benchmark measured warm p95 insertion-to-native-draw latency below 50 ms for 10-, 100-, and 300-page fixtures. See [measurements and methodology](docs/realtime-latency.md) for the values and scope. Cold engine/font startup and expensive or unsupported units are outside this fast-path result.

**Follow cursor** is enabled by default in the native toolbar. Mouse, arrow-key, and typing selection changes follow after a 150 ms pause, using fresh source spans and the cursor’s fraction through a unit’s rows, including page fragments. The preview scrolls only when the target leaves the central viewport; automatic following keeps editor focus and does not flash a marker. Turn the checkbox off to read elsewhere; `⌘J` still forces a jump. Click the PDF to navigate to a source unit; `⌘J` and outline navigation use rtex paragraph placements. Navigation targets units rather than individual glyphs. Native controls provide zoom, Fit, Recompile, and Export PDF. Export and quitting retain the clean two-pass build from the saved original source. If the engine exits or a cached source file is deleted, TexFast returns to its standard build driver and clears provisional overlays. This avoids silently compiling a deleted included file from the engine’s cache. A bundled supervisor cleans up the engine’s LuaLaTeX workers on shutdown or app process death; temporary concurrent-session builds are removed on exit; the leased startup cache is retained. Turning auto-compile off pauses sending edits until `⌘S`.

To build the alternative app:

```sh
./make-realtime-app.sh
```

The script downloads the pinned, SHA-256-verified engine release with its matching Lua resources, builds Swift with Xcode tools, and signs the separate bundle. It packages only the native app, engine/support files, icon, and relevant licenses. The standard `./make-app.sh` workflow remains available.

Validation:

```sh
xcrun --toolchain default swift test
python3 scripts/test-realtime-engine.py
./scripts/test-engine-updates.sh  # actual GitHub download, native Install button, isolated rollback
./scripts/test-realtime-native.sh  # after building TexFast Realtime.app; opens a disposable native window
./scripts/test-realtime-audit.sh  # renderer, editor lifecycle, and actual hung-engine cleanup
./scripts/test-realtime-startup.sh  # native follow behavior, cold fixture, cache reopening
./scripts/test-realtime-fidelity.sh
./scripts/test-realtime-latency.sh
./scripts/test-realtime-live-edit.sh  # visible unsaved typing and newly split paragraphs
./scripts/test-realtime-page-preview.sh  # complete early pages, PDF fidelity, failed-pass rollback
```

The engine test checks live edits, included-file UTF-8 edits, convergence, export, and source safety. The native test runs the Swift bridge and PDFKit pane against actual LuaLaTeX output, covering unsaved rapid edits, included-file edits, selectable text, math/TikZ rendering, page/zoom retention, corrupt PDFs, shrinking documents, and toolbar actions. It saves `.build/realtime-native-preview-smoke.png`. The audit checks per-unit revision ordering, nested color stacks, removed units, missing-font caching and recovery, cropped/rotated-page fallback, Unicode normalization reloads, source navigation, autosave reasons, shutdown timers, and complete worker cleanup after quit, EOF, termination, and app process death. The startup test drives the production editor and PDFKit preview, checking selection-only cursor following, viewport stability, focus retention, the Follow toggle, forced navigation, included-file targets, and cached reopening. It accepts an optional path to benchmark a real project without editing its sources. The live-edit test uses the production editor to verify a newly split paragraph visibly paints before a PDF containing it, then types continuously without saving or requesting a PDF per edit; it accepts an optional real-project path. The fidelity test requests a full layout only after capturing the live image for its comparison oracle, and the latency test drives the production NSTextView editor through actual PDFKit overlay drawing.

The following documents the standard TexFast pipeline retained for fallback and final output.


TexFast is a native macOS LaTeX editor with a LuaLaTeX preview loop. It pairs a source editor and PDF viewer with `fastex`, a command-line build driver that caches expensive figures and images during drafting. Final builds use the original assets and two LuaLaTeX passes.

## Requirements and installation

- macOS 13 or later.
- A TeX installation with `lualatex`, `synctex`, and `luatexja-fontspec` available (for example, MacTeX). TexFast also checks `/Library/TeX/texbin` when launched from Finder.
- [texlab](https://github.com/latex-lsp/texlab) is optional but needed for language-server completions, diagnostics, and outline data. On a Mac with Homebrew: `brew install texlab`.

Download `TexFast-v1.1.1-macOS.zip` from [Releases](https://github.com/kenny-21342/texfast/releases), unzip it, and move `TexFast.app` to `/Applications`. The release is ad-hoc signed and is not notarized, so macOS may ask you to approve opening it.

## Using the editor

1. Open a `.tex` document from the home screen or with **File → Open**. Open the root file of a project (usually `main.tex`) to make it the build target.
2. Edit in the middle pane and watch the draft PDF on the right. Auto-compile is on by default; TexFast saves and starts a preview shortly after you stop typing. Use **File → Auto-compile on Save** to change this, or press `⌘S` to save and build immediately.
3. Use the project files and document outline in the left sidebar. Click an outline entry to navigate the source and PDF; click a position in the PDF to jump to its source line. Drag files from Finder into the project tree to copy them into the project.
4. Quit normally to render the final PDF beside the root `.tex` file. The render window shows page progress when a previous preview provides a page count. TexFast stays open if the final build fails so you can inspect the error.

| Shortcut | Action |
| --- | --- |
| `⌘S` | Save and build |
| `⌘F` / `⌥⌘F` | Find / find and replace |
| `⌃Space` | Request completions |
| `⌘J` | Reveal the caret position in the PDF |
| `⌘0` / `⌘1` / `⌘2` | Toggle sidebar / terminal / Problems |
| `⌘,` | Open Settings |

## Core features

- Native AppKit editor with syntax highlighting, labeled line numbers, find and replace, and TeX-aware editing. It pairs `\begin` and `\end`, suggests commands and references through texlab, and helps insert `\item` in `itemize` and `enumerate` blocks. Inserted items remain editable and deletable.
- PDFKit preview with SyncTeX navigation in both directions, including source files included by the root document. The preview keeps its position across rebuilds.
- Independent hover previews for math, `\includegraphics`, TikZ, `tabular`, and `tabularx`. TexFast compiles the selected source snippet separately; it does not crop the main PDF. Toggle this in **TexFast → Settings**.
- Project tree with Finder drag and drop, document outline, Problems panel for compiler and texlab diagnostics, and a built-in terminal that starts in the project folder.
- Watches source and PDF changes made by other tools, including agents working in the terminal. Unsaved editor changes are protected from external overwrites.

## How the build works

`fastex` renders a **shadow source** under `.texfast/build-lualatex/`, leaving the project's `.tex` source unchanged. Its inline substitutions preserve source line numbers so errors and SyncTeX positions can map back to the real file. Build jobs share a lock to prevent the app and CLI from writing the same intermediate files at once.

For a draft, it hashes supported TikZ pictures and reuses their cached PDFs; pictures that cannot be externalized compile inline. It also converts eligible raster images to cached JPEGs. The app's live preview normally runs one LuaLaTeX pass, so changed cross-references may settle on the next preview. When a new edit makes a running preview obsolete, TexFast stops that build and compiles the latest saved version. The draft PDF lives at `.texfast/build-lualatex/<name>.pdf` and can differ slightly from the final PDF. LuaLaTeX writes the PDF directly, without a separate XDV conversion step.

A **final** build uses the original images, disables figure externalization, runs two LuaLaTeX passes, and writes `<name>.pdf` beside the root source. Quitting the app triggers this build after saving pending edits. Build speed depends on the document and its figures; a fresh figure cache takes longer than subsequent previews.

The build uses `-shell-escape` for figure externalization, so open and compile only TeX projects you trust.

## Command-line driver

`fastex` is bundled at `TexFast.app/Contents/MacOS/fastex`. Call it by that path, or add it to your `PATH`:

```sh
fastex warm main.tex             # populate the figure cache
fastex build --preview main.tex  # one-pass draft for quick feedback
fastex build main.tex            # draft; rerun if references change
fastex build --final main.tex    # two-pass final PDF beside main.tex
fastex clean main.tex            # remove the project's .texfast cache
```

## Build from source

Xcode Command Line Tools or Xcode with a Swift 5.9-compatible toolchain are required. From the repository root:

```sh
./make-app.sh
open TexFast.app
```

The script builds both executables in release mode, assembles `TexFast.app`, bundles the SwiftTerm license, and ad-hoc signs the app. To install that local build:

```sh
ditto TexFast.app /Applications/TexFast.app
```

The terminal pane uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), pinned in `Package.resolved`.
