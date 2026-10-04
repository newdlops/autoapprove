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
        .target(name: "CPTY", exclude: ["vendor/libvterm/LICENSE", "vendor/libvterm/UPSTREAM.md"], cSettings: [.headerSearchPath("vendor/libvterm/include"), .headerSearchPath("vendor/libvterm/src")]),
        .target(name: "AutoApproveCore", dependencies: ["CSQLite", "CPTY"], resources: [.copy("Resources/RemoteWeb")]),
        .executableTarget(name: "AutoApproveApp", dependencies: ["AutoApproveCore"]),
        .executableTarget(name: "AutoApproveCLI", dependencies: ["AutoApproveCore"]),
        .executableTarget(name: "AutoApproveChecks", dependencies: ["AutoApproveCore"], path: "Tests/AutoApproveCoreTests", swiftSettings: [.unsafeFlags(["-parse-as-library"])])
    ],
    swiftLanguageModes: [.v5]
)
