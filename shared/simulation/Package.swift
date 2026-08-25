// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "PewPewSimulation",
  platforms: [
    .iOS(.v17),
    .macOS(.v13),
  ],
  products: [
    .library(name: "PewPewSimulation", targets: ["PewPewSimulation"])
  ],
  targets: [
    .target(
      name: "PewPewSimulation",
      path: "Sources/PewPewSimulation"
    ),
    .testTarget(
      name: "PewPewSimulationTests",
      dependencies: ["PewPewSimulation"],
      path: "Tests/PewPewSimulationTests"
    ),
  ]
)
