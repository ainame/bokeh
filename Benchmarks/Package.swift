// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "fltr-benchmarks",
    platforms: [
        .macOS(.v26),
    ],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "matcher-benchmark",
            dependencies: [
                .product(name: "FltrLib", package: "fltr"),
            ],
            path: "Sources/MatcherBenchmark"
        ),
        .executableTarget(
            name: "comparison-bench-fltr",
            dependencies: [
                .product(name: "FltrLib", package: "fltr"),
            ],
            path: "Sources/ComparisonBenchFltr"
        ),
        .executableTarget(
            name: "comparison-quality-fltr",
            dependencies: [
                .product(name: "FltrLib", package: "fltr"),
            ],
            path: "Sources/ComparisonQualityFltr"
        ),
    ]
)
