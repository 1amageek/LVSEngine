// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "LVSEngine",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LVSCore", targets: ["LVSCore"]),
        .library(name: "LVSNetlistParsing", targets: ["LVSNetlistParsing"]),
        .library(name: "LVSNative", targets: ["LVSNative"]),
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
        .package(path: "../semiconductor-layout"),
    ],
    targets: [
        .target(name: "LVSCore"),
        .target(name: "LVSNetlistParsing", dependencies: ["LVSCore"]),
        .target(
            name: "LVSNative",
            dependencies: [
                "LVSCore",
                "LVSNetlistParsing",
                .product(name: "LayoutCore", package: "semiconductor-layout"),
                .product(name: "LayoutTech", package: "semiconductor-layout"),
                .product(name: "LayoutVerify", package: "semiconductor-layout"),
                .product(name: "LayoutIO", package: "semiconductor-layout"),
            ]
        ),
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
            dependencies: [
                "LVSCore",
                "LVSNative",
                "LVSAdapters",
                "LVSExtractionAdapters",
                "LVSPersistence",
                .product(name: "LayoutAutoGen", package: "semiconductor-layout"),
                .product(name: "LayoutCore", package: "semiconductor-layout"),
                .product(name: "LayoutTech", package: "semiconductor-layout"),
                .product(name: "LayoutIO", package: "semiconductor-layout"),
            ]
        ),
        .target(
            name: "LVSEngine",
            dependencies: ["LVSCore", "LVSNetlistParsing", "LVSNative", "LVSParsers", "LVSAdapters", "LVSExtractionAdapters", "LVSPersistence", "LVSRuntime"]
        ),
        .target(
            name: "LVSCLICore",
            dependencies: [
                "LVSEngine",
                .product(name: "SignoffToolSupport", package: "SignoffToolSupport"),
            ]
        ),
        .executableTarget(name: "LVSCLI", dependencies: ["LVSCLICore"], path: "Sources/LVSCLI"),
        .testTarget(name: "LVSAdaptersTests", dependencies: ["LVSAdapters", "LVSCore"]),
        .testTarget(name: "LVSExtractionAdaptersTests", dependencies: ["LVSExtractionAdapters", "LVSCore"]),
        .testTarget(
            name: "LVSNativeTests",
            dependencies: [
                "LVSNative",
                "LVSCore",
                "LVSNetlistParsing",
                .product(name: "LayoutCore", package: "semiconductor-layout"),
                .product(name: "LayoutTech", package: "semiconductor-layout"),
                .product(name: "LayoutIO", package: "semiconductor-layout"),
                .product(name: "LayoutAutoGen", package: "semiconductor-layout"),
            ]
        ),
        .testTarget(name: "LVSParsersTests", dependencies: ["LVSParsers", "LVSCore"]),
        .testTarget(name: "LVSRuntimeTests", dependencies: ["LVSRuntime", "LVSCore"]),
        .testTarget(
            name: "LVSCLICoreTests",
            dependencies: ["LVSCLICore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
