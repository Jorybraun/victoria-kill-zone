// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "VictoriaKillZoneDomain",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "VictoriaKillZone", targets: ["VictoriaKillZone"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/get-convex/convex-swift.git",
      exact: "0.8.1"
    ),
    .package(path: "../../shared/simulation"),
    .package(path: "Transport/CombatTransport"),
  ],
  targets: [
    .target(
      name: "VictoriaKillZone",
      dependencies: [
        .product(name: "ConvexMobile", package: "convex-swift"),
        .product(name: "PewPewSimulation", package: "simulation"),
        .product(name: "CombatTransport", package: "CombatTransport"),
      ],
      path: "VictoriaKillZone",
      exclude: [
        "App/VictoriaKillZoneApp.swift",
        "Info.plist",
        "Assets.xcassets",
        "PrivacyInfo.xcprivacy",
      ],
      resources: [
        .copy("Features/Game/SkeletonAssets"),
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
