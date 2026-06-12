// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "LVSEngine",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LVSCore", targets: ["LVSCore"]),
        .library(name: "LVSPureSwift", targets: ["LVSPureSwift"]),
        .library(name: "LVSParsers", targets: ["LVSParsers"]),
        .library(name: "LVSAdapters", targets: ["LVSAdapters"]),
        .library(name: "LVSExtractionAdapters", targets: ["LVSExtractionAdapters"]),
        .library(name: "LVSPersistence", targets: ["LVSPersistence"]),
        .library(name: "LVSRuntime", targets: ["LVSRuntime"]),
        .library(name: "LVSEngine", targets: ["LVSEngine"]),
        .library(name: "LVSCLICore", targets: ["LVSCLICore"]),
        .executable(name: "lvsengine", targets: ["LVSCLI"]),
    ],
    dependencies: [
        .package(path: "../SignoffToolSupport"),
    ],
    targets: [
        .target(name: "LVSCore"),
        .target(name: "LVSPureSwift", dependencies: ["LVSCore"]),
        .target(name: "LVSParsers", dependencies: ["LVSCore"]),
        .target(
            name: "LVSAdapters",
            dependencies: [
                "LVSCore",
                "LVSParsers",
                .product(name: "SignoffToolSupport", package: "SignoffToolSupport"),
            ],
            resources: [.copy("Resources/lvs.tcl")]
        ),
        .target(
            name: "LVSExtractionAdapters",
            dependencies: [
                "LVSCore",
                .product(name: "SignoffToolSupport", package: "SignoffToolSupport"),
            ],
            resources: [.copy("Resources/extract_lvs.tcl")]
        ),
        .target(name: "LVSPersistence", dependencies: ["LVSCore"]),
        .target(
            name: "LVSRuntime",
            dependencies: ["LVSCore", "LVSPureSwift", "LVSAdapters", "LVSExtractionAdapters", "LVSPersistence"]
        ),
        .target(
            name: "LVSEngine",
            dependencies: ["LVSCore", "LVSPureSwift", "LVSParsers", "LVSAdapters", "LVSExtractionAdapters", "LVSPersistence", "LVSRuntime"]
        ),
        .target(name: "LVSCLICore", dependencies: ["LVSEngine"]),
        .executableTarget(name: "LVSCLI", dependencies: ["LVSCLICore"], path: "Sources/LVSCLI"),
        .testTarget(name: "LVSAdaptersTests", dependencies: ["LVSAdapters", "LVSCore"]),
        .testTarget(name: "LVSExtractionAdaptersTests", dependencies: ["LVSExtractionAdapters", "LVSCore"]),
        .testTarget(name: "LVSPureSwiftTests", dependencies: ["LVSPureSwift", "LVSCore"]),
        .testTarget(name: "LVSParsersTests", dependencies: ["LVSParsers", "LVSCore"]),
        .testTarget(name: "LVSRuntimeTests", dependencies: ["LVSRuntime", "LVSCore"]),
        .testTarget(name: "LVSCLICoreTests", dependencies: ["LVSCLICore"]),
    ]
)
