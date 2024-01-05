// swift-tools-version:5.5

import PackageDescription

let package = Package(
    name: "llama",
    platforms: [
        .macOS(.v12),
        .iOS(.v14),
        .watchOS(.v4),
        .tvOS(.v14)
    ],
    products: [
        .library(name: "llama", targets: ["llama"]),
    ],
    dependencies: [
        .package(url: "https://github.com/illescasDaniel/ggml", .revision("9e822a6b3c093a2cd3d98e4bcb1f2b734e0eb1fe"))
    ],
    targets: [
        .target(
            name: "llama",
            dependencies: ["ggml"],
            path: ".",
            exclude: [],
            sources: [
                "llama.cpp",
            ],
            publicHeadersPath: "spm-headers",
            cSettings: [
                .unsafeFlags(["-Wno-shorten-64-to-32", "-O3", "-DNDEBUG"]),
                .define("GGML_USE_ACCELERATE"),
                .unsafeFlags(["-fno-objc-arc"]),
                .define("GGML_USE_METAL"),
                .define("ACCELERATE_NEW_LAPACK"),
                .define("ACCELERATE_LAPACK_ILP64")
            ],
            linkerSettings: [
                .linkedFramework("Accelerate")
            ]
        )
    ],
    cxxLanguageStandard: .cxx11
)
