// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "e-volv-logs-swift",
    platforms: [
        .macOS(.v13),
        .iOS(.v15),
    ],
    products: [
        .library(name: "EvolveLogs", targets: ["EvolveLogs"]),
        .executable(name: "conformance-runner", targets: ["conformance-runner"]),
    ],
    targets: [
        .target(
            name: "EvolveLogsC",
            path: "Sources/EvolveLogsC",
            linkerSettings: [
                // gzip bodies (Transport.gzip → Gzip.c over the system zlib).
                .linkedLibrary("z"),
            ]
        ),
        .target(
            name: "EvolveLogs",
            dependencies: ["EvolveLogsC"],
            path: "Sources/EvolveLogs"
        ),
        .executableTarget(
            name: "conformance-runner",
            dependencies: ["EvolveLogs"],
            path: "Sources/conformance-runner"
        ),
        .testTarget(
            name: "EvolveLogsTests",
            dependencies: ["EvolveLogs", "EvolveLogsC"],
            path: "Tests/EvolveLogsTests"
        ),
    ]
)
