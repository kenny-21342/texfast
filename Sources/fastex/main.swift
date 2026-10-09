import Foundation
import TexFastCore

func usage() -> Never {
    print("""
    fastex — a fast incremental build driver for LuaLaTeX documents

    USAGE
      fastex build [--final|--preview] [-j N] <file.tex>
                                                 compile (draft by default)
      fastex warm  [-j N] <file.tex>             populate the figure cache only
      fastex clean <file.tex>                    drop the cache

    Draft builds downsample raster images to cached JPEGs and reuse externalized
    TikZ figures; the PDF stays in .texfast/build-lualatex/. --final uses the original
    images, runs two passes and writes the PDF next to the source. --preview
    uses one pass for a faster draft. The source is never modified.
    """)
    exit(0)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
args.removeFirst()
if command == "-h" || command == "--help" { usage() }

var draft = true
var previewOnly = false
var jobs = ProcessInfo.processInfo.activeProcessorCount
var path: String? = nil

var i = 0
while i < args.count {
    switch args[i] {
    case "--final": draft = false
    case "--draft": draft = true
    case "--preview": previewOnly = true
    case "-j", "--jobs":
        i += 1
        guard i < args.count, let n = Int(args[i]) else { fail("-j needs a number") }
        jobs = max(1, n)
    default:
        if args[i].hasPrefix("-") { fail("unknown option \(args[i])") }
        path = args[i]
    }
    i += 1
}

guard let path else { usage() }
if previewOnly && !draft { fail("--preview cannot be combined with --final") }
let texFile = URL(fileURLWithPath: path).standardizedFileURL
guard FileManager.default.fileExists(atPath: texFile.path) else { fail("no such file: \(path)") }
let projectDir = texFile.deletingLastPathComponent()
let cacheDir = projectDir.appendingPathComponent(".texfast")

switch command {
case "clean":
    try? FileManager.default.removeItem(at: cacheDir)
    print("removed \(cacheDir.path)")

case "warm", "build":
    let driver = Driver(texFile: texFile, projectDir: projectDir, cacheDir: cacheDir,
                        draft: draft, jobs: jobs)
    let r = driver.build(figuresOnly: command == "warm", previewOnly: previewOnly)
    if let error = r.error { fail(error) }

    var bits: [String] = []
    if r.imagesConverted > 0 { bits.append("\(r.imagesConverted) image(s) converted") }
    else if r.imagesLinked > 0 { bits.append("\(r.imagesLinked) image(s) from cache") }
    bits.append("\(r.figuresCached) figure(s) cached")
    if r.figuresBuilt > 0 { bits.append("\(r.figuresBuilt) built in \(fmt(r.figureSeconds))") }
    if !r.figuresFailed.isEmpty { bits.append("\(r.figuresFailed.count) inline fallback") }
    log("fastex: " + bits.joined(separator: ", "))

    if command == "build" {
        log(String(format: "fastex: tex %@ · %d pass(es)",
                   fmt(r.texSeconds), r.passes))
        log("fastex: total \(fmt(r.totalSeconds))")
        if let pdf = r.pdf { print(pdf.path) }
    } else {
        log("fastex: total \(fmt(r.totalSeconds))")
    }

default:
    fail("unknown command '\(command)' (try: build, warm, clean)")
}

func fmt(_ s: Double) -> String { String(format: "%.2fs", s) }
