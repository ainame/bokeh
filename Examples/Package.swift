// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "fltr-examples",
    platforms: [
        .macOS(.v26),
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/apple/swift-system", from: "1.7.5"),
    ],
    targets: [
        .target(
            name: "DeclarativeTUI",
            dependencies: [
                .product(name: "TUI", package: "fltr"),
            ],
            path: "DeclarativeTUI",
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "tui-demo",
            dependencies: [
                .product(name: "TUI", package: "fltr"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            path: "TUIDemo"
        ),
        .executableTarget(
            name: "declarative-demo",
            dependencies: [
                "DeclarativeTUI",
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            path: "DeclarativeDemo"
        ),
    ]
)
