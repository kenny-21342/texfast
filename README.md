# TexFast

A lightweight native LaTeX editor for macOS, and the fast build driver behind it.

Built for a 9,000-line, 110-page XeLaTeX document whose full compile took
1–1.5 minutes and whose editor (VS Code + LaTeX Workshop) cost 1–2 GB of RAM.

## Why it is fast

Profiling the real document showed the time was not in TeX's own work:

| Phase | Before | After | How |
|---|---|---|---|
| Preamble | 1.7 s | 1.7 s | untouched |
| Body (116 tikzpicture, 3 circuitikz, 14 pgfplots) | ~31 s | ~5 s | figures externalized to cached PDFs |
| `xdvipdfmx` (58 retina PNGs, 25.6 MB) | ~22 s | ~1 s | images cached as JPEG |
| **Full 110-page build** | **~46 s ×2 passes** | **6.6 s** | |

The image win is the larger surprise: `xdvipdfmx` copies a JPEG's DCTDecode
stream into the PDF verbatim, but inflates and re-deflates every PNG on every
run. Downsampling the screenshots to 800 px JPEG cut that phase from 22 s to
under a second, and the PDF from 16 MB to ~4 MB.

## Your source is never modified

Each build renders a *shadow copy* into `.texfast/build/`. Every edit it makes —
externalization setup, rewritten image paths — is inserted inline, so the shadow
has byte-identical line numbering. SyncTeX positions and error line numbers keep
pointing at your real `main.tex`.

## fastex (CLI)

```sh
fastex warm  main.tex     # one-time: build the figure cache (~3.5 min on 8 cores)
fastex build main.tex     # draft build, ~6.6 s; PDF at .texfast/build/main.pdf
fastex build --final main.tex   # exact, stock-equivalent PDF next to the source
fastex clean main.tex     # drop the cache
```

**Draft** is the edit loop: cached JPEGs, cached figures, ~6.6 s, PDF stays in
`.texfast/build/`. **Final** is the PDF you print or hand in: original images,
*no* externalization, written next to the source, ~110 s.

Final deliberately gives up all the caching. An externalized figure carries a
tight bounding box, which nudges the horizontal spacing of side-by-side figures
by a fraction of a point — invisible while writing, but not something the
handed-in PDF should carry. With externalization off, `--final` renders
**pixel-identical to a stock `xelatex` run across all 110 pages** (verified by
rasterising both at 55 dpi and diffing: 0 pages differ).

Measured on the IB Physics notes (M3, 8 cores): `warm` ~3.5 min once, then draft
builds 6.6 s. Editing prose rebuilds no figures; editing one picture rebuilds
exactly one (~6 s).

Figures are cached by the md5 of the picture source, so prose edits rebuild
nothing and editing one picture rebuilds exactly that picture.

### Externalization is opt-in, per picture

Only pictures the scanner recognises (`tikzpicture`, `circuitikz`) are named and
cached; externalization is switched off everywhere else. This matters: enabling
it globally makes tikz *discard* any picture it has no cached PDF for, printing
`[[ IMAGE DISCARDED DUE TO '/tikz/external/mode=list and make' ]]` in its place.
The notes use `\tikz{...}` shorthand for the circuit-symbol table on page 42, and
that is exactly how it was lost. Anything unrecognised now simply compiles
inline, as it always did.

### Pictures that cannot be externalized

Some pictures genuinely cannot be shipped to their own PDF — `circuitikz`
environments in particular, and any picture referencing a node defined in
another picture. `fastex` detects these, records them in
`.texfast/blocked-figures.txt`, and compiles them inline instead of dropping
them. When a picture references a node (`No shape named 'axis1'`), the picture
that *defines* that node is kept inline too, or the fallback would still render
nothing.

### What did not work

Precompiling the preamble with `mylatexformat` looked attractive — it cut
preamble load from 3.2 s to 0.5 s — but the resulting format segfaults XeTeX
(signal 11) the moment the document uses `xeCJK` fonts or TikZ. The fonts get
frozen into the format and the real run cannot recover them. Not viable here.

## TexFast.app

Native AppKit. No web view, no Electron, no Tauri — about 100 MB resident,
plus ~30 MB for the language server.

- **Left:** outline of sections, from texlab's document symbols.
- **Middle:** editor. `\begin{env}` writes its own `\end{env}`.
  Native find and replace is available with `⌘F` and `⌥⌘F`.

Three things about the text view matter at this size, all learned the hard way:

- **Highlighting uses temporary attributes on the layout manager**, never the
  text storage. Mutating storage invalidates layout, and with a scroll in flight
  the relayout emits another bounds change, which re-enters highlighting. For the
  same reason the font never varies — a metrics change would relayout and shift
  the scroll position underfoot. Diagnostics are scoped the same way; the first
  version cleared attributes across all 429 KB on every texlab update.
- **Non-contiguous layout is off.** It sounds right for a 9,000-line file, but it
  lays out lazily and estimates the rest, so the scroller thumb jumps as
  estimates are refined and dragging it forces a big synchronous layout. Laying
  the document out once costs well under a second (1.9 s to a responsive window,
  including app launch) and buys exact, instant scrolling.
- **The text container is pinned to the pane width** on every layout pass.
  Without it the text view was 1219 pt wide inside a 619 pt pane, so long lines
  ran off the right edge with no way to reach them.

A hand-built NSTextView also needs an explicit `maxSize`; it otherwise refuses to
grow past its initial frame, which pins the document at one screenful.
- **Right:** PDFKit preview. Reloads keep your page and scroll offset.

**Home screen.** Launching without a file shows a start window listing recently
opened documents (File ▸ Home to get back to it). Recents are kept in
`UserDefaults` under `TexFastRecentDocuments`, not via
`NSDocumentController.recentDocumentURLs` — TexFast is not built on the
NSDocument architecture, so that API records nothing it can read back and the
list stayed permanently empty.

Entries can be forgotten: select rows and press `⌫`, or right-click for
**Remove from Recents** / **Clear All Recents**; both are also in the File menu
(**Remove Selected from Recents**, **Clear Recent Files**) so they work without
a right-click. The context menu acts on the row under the cursor when it is
outside the selection, and on the whole selection otherwise; after a removal the
selection moves to the row that took its place, so repeated deletes need no
re-aiming.

Path comparison there goes through one canonical form on **both** sides.
`standardizedFileURL` alone is not enough — it rewrites `/private/tmp` to
`/tmp`, so a stored path and the URL built from it disagree, the removal filter
matches nothing, and the entry silently stays put. This was a real bug, not a
hypothetical: it made removal a no-op for any recent stored under a symlinked
prefix.

**Find and replace** is AppKit's own find bar (`⌘F`, `⌘G`/`⇧⌘G` for next and
previous, `⌘E` to search for the selection, `⌥⌘F` to replace). Note that
`performTextFinderAction:` dispatches on each menu item's `tag`: leaving it at
the default `0` is not "show the find bar", it is not a valid
`NSTextFinder.Action` at all, and `⌘F` silently does nothing.

Builds are serialised by an advisory lock on `.texfast/build.lock`, so running
`fastex` in a terminal while the app is open queues rather than corrupting the
shared `.xdv`. Build output is appended to `.texfast/build.log`, since stderr
goes nowhere when the app is launched from Finder.

Completion, diagnostics, go-to-definition and symbols all come from
[`texlab`](https://github.com/latex-lsp/texlab) — install it with
`brew install texlab`. Without it the editor still works; completion is off.

**Live updates from other processes.** TexFast watches both the source file and
the PDF. If a coding agent, another editor, or a `fastex` run from a terminal
rewrites `main.tex`, the editor reloads it in place — keeping your caret and
scroll position — refreshes the outline, and (when auto-compile is on) rebuilds,
so the preview follows. The PDF is watched independently, so a build started
anywhere refreshes the preview as soon as `xdvipdfmx` has finished.

Two details make this safe rather than annoying:

- **Your unsaved typing is never discarded.** If the file changes on disk while
  the buffer is dirty, TexFast refuses to reload and says so; File ▸ Reload from
  Disk (`⌘R`) takes theirs, `⌘S` takes yours.
- **The watchers poll and wait for the file to settle.** Polling, because most
  writers save atomically by renaming a temp file over the original, which makes
  a vnode watch go deaf after the first save. Settling, because `xdvipdfmx`
  writes a 5 MB PDF progressively — reload it halfway through and you get a
  truncated document (during testing the PDF was caught at 0 bytes mid-write).

**Auto-compile on save** (on by default, File ▸ Auto-compile on Save). 1.2 s
after you stop typing, the file is saved and a build starts — no keystroke. It
refuses to auto-save when the file has changed on disk since TexFast last wrote
it, so an edit made in another editor is never clobbered by a background timer;
the status bar says so, and `⌘S` still overwrites deliberately. The setting
persists across launches.

| Shortcut | |
|---|---|
| `⌘S` | save and build now |
| `⌘F` | find in the current document |
| `⌥⌘F` | find and replace in the current document |
| `⇧⌘H` | show the home window and recent files |
| `⌫` | forget the selected entries on the home screen |
| `⌘R` | reload the file from disk |
| `⌃Space` | suggestions |
| `⌘J` | show the caret's position in the PDF |
| `⌘0` | toggle the outline |
| `⌘`-click in the editor | jump to that spot in the PDF |
| `⌘`-click in the PDF | jump to that line in the source |

## Install

```sh
./make-app.sh                                  # build TexFast.app + fastex
ditto TexFast.app /Applications/TexFast.app    # install
```

The icon is generated, not hand-drawn — `Resources/make-icon.py` renders it at
4x and downsamples, so it stays legible at 16px. Re-run that script and rebuild
to change it.

## Build

```sh
./make-app.sh          # builds TexFast.app and the fastex binary
```

The toolchain note: `SWIFTLY_TOOLCHAINS_DIR` points at a toolchain that is not
installed, so plain `swift build` fails. Everything here uses
`xcrun --toolchain default swift build`.

## Scope

TexFast is a personal tool, not a shipped project. It exists because the IB
Physics notes needed a fast edit loop on this machine; it is built for that
document and that user, and there is no release, no user base, and no support
burden. **It deliberately has no deadline** — it is worked on when the writing
it serves is slowed down by something, and left alone otherwise. That is the
recorded decision, not an oversight in the portfolio schedule.

It is also not a rival to `~/latex-visual-editor`, which is a different project
with a different audience: a Word-style *visual* editor for MCM teammates who do
not write LaTeX, shipping to a deadline. TexFast is the opposite — a plain
source editor for someone who does write LaTeX and wants the compile to stop
costing a minute. Both can exist because they solve different problems.

The Tauri/Electron question follows from that split rather than contradicting
it. `latex-visual-editor` is a Tauri app because it must reach teammates on
other machines; TexFast is native AppKit because it runs only here, and a
web-stack shell would spend RAM — the exact cost that motivated replacing
VS Code + LaTeX Workshop in the first place. The "no Tauri" rule is a TexFast
rule, scoped to this project on purpose.

`fastex` is the reusable half. It is a standalone CLI with no AppKit dependency,
so `latex-visual-editor` (or anything else compiling XeLaTeX) can adopt it for
the same build speedup without taking on any of TexFast's editor.
