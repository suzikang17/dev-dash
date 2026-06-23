// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DevDash",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DevDash", targets: ["DevDash"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "DevDashCore",
            path: "Sources/DevDashCore"
        ),
        .executableTarget(
            name: "DevDash",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                "DevDashCore"
            ],
            path: "Sources/DevDash",
            resources: [
                .copy("Resources")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "DevDashCoreTests",
            dependencies: ["DevDashCore"],
            path: "Tests/DevDashCoreTests"
        )
    ]
)
