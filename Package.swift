// swift-tools-version: 6.3
import PackageDescription
import Foundation

let workspaceRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()

let circuiteFoundationDependency: Package.Dependency = FileManager.default.fileExists(
    atPath: workspaceRoot.appendingPathComponent("CircuiteFoundation/Package.swift").path
)
    ? .package(path: "../CircuiteFoundation")
    : .package(
        url: "https://github.com/1amageek/CircuiteFoundation.git",
        revision: "2ec6ee13a89ac6885be3c26b41a9ee0ef89948ac"
    )

let signoffToolSupportDependency: Package.Dependency = FileManager.default.fileExists(
    atPath: workspaceRoot.appendingPathComponent("SignoffToolSupport/Package.swift").path
)
    ? .package(path: "../SignoffToolSupport")
    : .package(
        url: "https://github.com/1amageek/SignoffToolSupport.git",
        revision: "7bfd1864edd147c59a1dc79e58f297120d165323"
    )

let semiconductorLayoutDependency: Package.Dependency = FileManager.default.fileExists(
    atPath: workspaceRoot.appendingPathComponent("semiconductor-layout/Package.swift").path
)
    ? .package(path: "../semiconductor-layout")
    : .package(
        url: "https://github.com/1amageek/semiconductor-layout.git",
        revision: "fa8f27852bc251fb340dfcfa261f2b3a0a408d1a"
    )

let package = Package(
    name: "LVSEngine",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LVSGraph", targets: ["LVSGraph"]),
        .library(name: "LVSMatching", targets: ["LVSMatching"]),
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
        circuiteFoundationDependency,
        signoffToolSupportDependency,
        semiconductorLayoutDependency,
    ],
    targets: [
        .target(
            name: "LVSGraph",
            dependencies: [
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
            ]
        ),
        .target(name: "LVSMatching", dependencies: ["LVSGraph"]),
        .target(
            name: "LVSCore",
            dependencies: [
                "LVSGraph",
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
            ]
        ),
        .target(name: "LVSNetlistParsing", dependencies: ["LVSCore"]),
        .target(
            name: "LVSNative",
            dependencies: [
                "LVSCore",
                "LVSNetlistParsing",
                "LVSGraph",
                "LVSMatching",
                .product(name: "LayoutCore", package: "semiconductor-layout"),
                .product(name: "LayoutLVSExtraction", package: "semiconductor-layout"),
                .product(name: "LayoutTech", package: "semiconductor-layout"),
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
        .target(name: "LVSPersistence", dependencies: ["LVSCore", "LVSGraph"]),
        .target(
            name: "LVSRuntime",
            dependencies: [
                "LVSCore",
                "LVSNetlistParsing",
                "LVSNative",
                "LVSAdapters",
                "LVSExtractionAdapters",
                "LVSPersistence",
                .product(name: "LayoutAutoGen", package: "semiconductor-layout"),
                .product(name: "LayoutCore", package: "semiconductor-layout"),
                .product(name: "LayoutLVSExtraction", package: "semiconductor-layout"),
                .product(name: "LayoutTech", package: "semiconductor-layout"),
                .product(name: "LayoutIO", package: "semiconductor-layout"),
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
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
        .testTarget(name: "LVSMatchingTests", dependencies: ["LVSGraph", "LVSMatching"]),
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
        .testTarget(name: "LVSRuntimeTests", dependencies: ["LVSRuntime", "LVSPersistence", "LVSCore"]),
        .testTarget(
            name: "LVSCLICoreTests",
            dependencies: ["LVSCLICore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
