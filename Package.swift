// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "mapconductor-for-maplibre",
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "MapConductorForMapLibre",
            targets: ["MapConductorForMapLibre"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/MapConductor/ios-sdk-core", from: "1.0.0"),
        .package(url: "https://github.com/maplibre/maplibre-gl-native-distribution", from: "6.21.2"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "MapConductorForMapLibre",
            dependencies: [
                .product(name: "MapConductorCore", package: "ios-sdk-core"),
                .product(name: "MapLibre Native", package: "maplibre-gl-native-distribution"),
            ],
        ),
    ]
)
