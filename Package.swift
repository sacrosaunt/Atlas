// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "AtlasBackend",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(
            url: "https://github.com/hummingbird-project/hummingbird.git",
            exact: "2.25.1"
        ),
    ],
    targets: [
        .executableTarget(
            name: "AtlasBackend",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                "LlamaFramework",
            ],
            path: "swift-backend",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreML"),
                .linkedFramework("Security"),
            ]
        ),
        .binaryTarget(
            name: "LlamaFramework",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b10069/llama-b10069-xcframework.zip",
            checksum: "1014038b590e7d485857fea9123c4eb1abe816d2f5d0ca1d21ddcb9fa9ab944e"
        ),
    ]
)
