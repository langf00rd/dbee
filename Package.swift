// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Dbee",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Dbee", targets: ["Dbee"])],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.7.0"),
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.9.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "Dbee",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "MySQLNIO", package: "mysql-nio"),
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "Logging", package: "swift-log"),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "DbeeTests", dependencies: ["Dbee"]),
    ],
    swiftLanguageModes: [.v5]
)
