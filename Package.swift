// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DocumentReader",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "DocumentReader", targets: ["DocumentReader"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/ml-explore/mlx-swift",
            exact: "0.30.2"
        ),
        .package(
            url: "https://github.com/weichsel/ZIPFoundation.git",
            exact: "0.9.20"
        ),
        .package(
            url: "https://github.com/mlalma/MLXUtilsLibrary.git",
            exact: "0.0.5"
        ),
        .package(
            url: "https://github.com/BB9z/LAME-xcframework.git",
            exact: "3.100.3"
        )
    ],
    targets: [
        .target(
            name: "MisakiSwift",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary")
            ],
            path: "Vendor/MisakiSwift/Sources/MisakiSwift",
            resources: [.copy("../../Resources")]
        ),
        .target(
            name: "KokoroSwift",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                "MisakiSwift",
                .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary")
            ],
            path: "Vendor/KokoroSwift/Sources/KokoroSwift",
            resources: [.copy("../../Resources")]
        ),
        .executableTarget(
            name: "DocumentReader",
            dependencies: [
                "KokoroSwift",
                "ZIPFoundation",
                .product(name: "LAME", package: "LAME-xcframework"),
                "Sparkle",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary")
            ],
            path: "Sources/DocumentReader",
            resources: [.process("Resources")]
        ),
        .binaryTarget(
            name: "Sparkle",
            url: "https://github.com/sparkle-project/Sparkle/releases/download/2.9.2/Sparkle-for-Swift-Package-Manager.zip",
            checksum: "b83e37436774556ed055e0244b297ef2c790e0737393bf65bf495fcbba6eed65"
        ),
        .testTarget(
            name: "DocumentReaderTests",
            dependencies: ["DocumentReader", "ZIPFoundation"],
            path: "Tests/DocumentReaderTests"
        )
    ]
)
