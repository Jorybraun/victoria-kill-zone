// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "CombatAuthority",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "CombatAuthority", targets: ["CombatAuthority"])
  ],
  dependencies: [
    .package(path: "../../../../shared/simulation"),
    .package(path: "../../Transport/CombatTransport"),
  ],
  targets: [
    .target(
      name: "CombatAuthority",
      dependencies: [
        .product(name: "PewPewSimulation", package: "simulation"),
        .product(name: "CombatTransport", package: "CombatTransport"),
      ],
      path: "Sources/CombatAuthority"
    ),
    .testTarget(
      name: "CombatAuthorityTests",
      dependencies: [
        "CombatAuthority",
        .product(name: "PewPewSimulation", package: "simulation"),
        .product(name: "CombatTransport", package: "CombatTransport"),
      ],
      path: "Tests/CombatAuthorityTests"
    ),
  ]
)
