// swift-tools-version: 5.9
//
// CI-only replacement manifest for masicai/onnxruntime-swift-package-manager@1.28.0.
// The upstream manifest also declares an `onnxruntime_extensions` binary target that
// points at download.onnxruntime.ai, which is currently offline. flutter_onnxruntime
// never uses that product, so this manifest keeps only the core `onnxruntime` library.

import PackageDescription

let package = Package(
    name: "onnxruntime",
    platforms: [.iOS(.v15),
                .macOS(.v14)],
    products: [
        .library(name: "onnxruntime",
                 type: .static,
                 targets: ["OnnxRuntimeBindings"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "OnnxRuntimeBindings",
                dependencies: ["onnxruntime"],
                path: "objectivec",
                exclude: ["ReadMe.md", "format_objc.sh", "test", "docs",
                          "ort_checkpoint.mm",
                          "ort_checkpoint_internal.h",
                          "ort_training_session_internal.h",
                          "ort_training_session.mm",
                          "include/ort_checkpoint.h",
                          "include/ort_training_session.h",
                          "include/onnxruntime_training.h"],
                cxxSettings: [
                    .define("SPM_BUILD"),
                ]),
        .binaryTarget(name: "onnxruntime",
                      url: "https://github.com/masicai/onnxruntime-swift-package-manager/releases/download/1.28.0/onnxruntime-libs-1.28.0.zip",
                      checksum: "7e031979787f2da0f3ff45d18431db93c4443033020b210413b287a855870c3c"),
    ],
    cxxLanguageStandard: .cxx17
)
