// swift-tools-version:6.0
import PackageDescription

// Release builds: full optimisation (-O), whole-module and cross-module optimisation so the
// engine's small hot functions inline across PicttyCore and Pictty, no runtime exclusivity checks,
// code scheduled for Apple silicon (M1 and later), and dead code stripped at link time.
// Bounds and overflow checks stay on (-O, not -Ounchecked): the heavy lifting is in
// ImageIO, vImage and Core Animation, so removing them would buy nothing measurable.
let optimised: [SwiftSetting] = [
    .unsafeFlags(["-O", "-wmo", "-cross-module-optimization", "-enforce-exclusivity=unchecked",
                  "-target-cpu", "apple-m1"],
                 .when(configuration: .release)),
]

let package = Package(
    name: "Pictty",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "PicttyCore", swiftSettings: optimised),
        .executableTarget(
            name: "Pictty",
            dependencies: ["PicttyCore"],
            swiftSettings: optimised,
            linkerSettings: [.unsafeFlags(["-Xlinker", "-dead_strip"], .when(configuration: .release))]
        ),
        .testTarget(name: "PicttyCoreTests", dependencies: ["PicttyCore"]),
    ],
    swiftLanguageModes: [.v5]
)
