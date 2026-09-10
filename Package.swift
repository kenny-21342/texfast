// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "texfast",
    platforms: [.macOS(.v13)],
    targets: [
        // Shared build machinery: shadow source, caches, the driver.
        .target(name: "TexFastCore", path: "Sources/TexFastCore"),
        // The command line front end.
        .executableTarget(name: "fastex", dependencies: ["TexFastCore"], path: "Sources/fastex"),
        // The editor.
        .executableTarget(name: "TexFast", dependencies: ["TexFastCore"], path: "Sources/TexFast",
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])])
    ]
)
