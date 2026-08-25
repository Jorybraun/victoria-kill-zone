// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "CombatTransport",
  platforms: [
    .iOS(.v17),
    .macOS(.v13),
  ],
  products: [
    .library(name: "CombatTransport", targets: ["CombatTransport"])
  ],
  dependencies: [
    .package(path: "../../../shared/simulation")
  ],
  targets: [
    .target(
      name: "CombatTransport",
      path: "Sources/CombatTransport"
    ),
    .testTarget(
      name: "CombatTransportTests",
      dependencies: [
        "CombatTransport",
        .product(name: "PewPewSimulation", package: "simulation"),
      ],
      path: "Tests/CombatTransportTests"
    ),
  ]
)
