# TexFast

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
