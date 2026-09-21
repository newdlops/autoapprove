// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutoApprove",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AutoApproveApp", targets: ["AutoApproveApp"]),
        .executable(name: "autoapprove", targets: ["AutoApproveCLI"]),
        .executable(name: "autoapprove-checks", targets: ["AutoApproveChecks"]),
        .library(name: "AutoApproveCore", targets: ["AutoApproveCore"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "AutoApproveCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "AutoApproveApp", dependencies: ["AutoApproveCore"]),
        .executableTarget(name: "AutoApproveCLI", dependencies: ["AutoApproveCore"]),
        .executableTarget(name: "AutoApproveChecks", dependencies: ["AutoApproveCore"], path: "Tests/AutoApproveCoreTests", swiftSettings: [.unsafeFlags(["-parse-as-library"])])
    ],
    swiftLanguageModes: [.v5]
)
