// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Margins",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Margins", targets: ["Margins"]),
        .executable(name: "margins-cli", targets: ["MarginsCLI"]),
    ],
    targets: [
        .target(name: "MarginsCore"),
        .executableTarget(
            name: "Margins",
            dependencies: ["MarginsCore"],
            resources: [.copy("Resources/Editor")]
        ),
        .executableTarget(name: "MarginsCLI", dependencies: ["MarginsCore"]),
        // Command Line Tools ship without XCTest / swift-testing macros, so tests run as an executable.
        .executableTarget(name: "MarginsSelfTest", dependencies: ["MarginsCore"], path: "Tests/MarginsSelfTest"),
    ]
)
