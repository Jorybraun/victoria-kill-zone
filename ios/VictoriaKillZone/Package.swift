// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "VictoriaKillZoneDomain",
  platforms: [
    .iOS(.v17),
    .macOS(.v13),
  ],
  products: [
    .library(name: "VictoriaKillZone", targets: ["VictoriaKillZone"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/get-convex/convex-swift.git",
      exact: "0.8.1"
    )
  ],
  targets: [
    .target(
      name: "VictoriaKillZone",
      dependencies: [
        .product(name: "ConvexMobile", package: "convex-swift")
      ],
      path: "VictoriaKillZone",
      exclude: [
        "App/VictoriaKillZoneApp.swift",
        "Info.plist",
      ],
      sources: [
        "App/AppEnvironment.swift",
        "App/RootView.swift",
        "DesignSystem",
        "Domain",
        "Features",
        "Services",
        "Targeting/TargetingSession.swift",
        "Targeting/SharedArena",
      ],
      linkerSettings: [
        .linkedFramework("AVFoundation", .when(platforms: [.iOS])),
        .linkedFramework("Speech", .when(platforms: [.iOS])),
      ]
    ),
    .testTarget(
      name: "VictoriaKillZoneTests",
      dependencies: ["VictoriaKillZone"],
      path: "VictoriaKillZoneTests"
    ),
  ]
)
