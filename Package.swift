// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "texfast",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.10.0")
    ],
    targets: [
        // Shared build machinery: shadow source, caches, the driver.
        .target(name: "TexFastCore", path: "Sources/TexFastCore"),
        // The command line front end.
        .executableTarget(name: "fastex", dependencies: ["TexFastCore"], path: "Sources/fastex"),
        // The editor.
        .executableTarget(name: "TexFast", dependencies: [
            "TexFastCore", .product(name: "SwiftTerm", package: "SwiftTerm")
        ], path: "Sources/TexFast",
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"])])
    ]
)
