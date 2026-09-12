// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "GRDBLogging",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .watchOS(.v9),
        .tvOS(.v16),
        .visionOS(.v1),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "GRDBLogging",
            targets: ["GRDBLogging"]
        )
    ],
    dependencies: [
        // swift-log defines the `Logger` API this package implements a backend for.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        // SwiftLogExport provides the `LogRecord`/`LogRecordExporter`/`BatchLogRecordProcessor` pipeline
        // plus the @_spi(Testing) buffer accessors used by the drain tests.
        .package(
            url: "https://github.com/atacan/SwiftLogExport.git",
            revision: "b8f0b7747fa1a50444bc86e3950cf411645ff2ce"
        ),
        // GRDB provides the SQLite persistence layer every log record is inserted into.
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        .target(
            name: "GRDBLogging",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SwiftLogExport", package: "SwiftLogExport"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "GRDBLoggingTests",
            dependencies: ["GRDBLogging"]
        ),
    ]
)
