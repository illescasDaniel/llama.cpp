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
    dependencies: [],
    targets: [
        .target(
            name: "llama",
            dependencies: [],
            path: ".",
            exclude: [],
            sources: [
                "llama.cpp",
                "ggml.c",
                "ggml-alloc.c",
                "ggml-backend.c",
                "ggml-quants.c",
                "ggml-metal.m",
            ],
            resources: [
                .process("ggml-metal.metal")
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
