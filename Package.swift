// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mapconductor-for-maplibre",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "MapConductorForMapLibre",
            targets: ["MapConductorForMapLibre"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/MapConductor/ios-sdk-core", from: "1.0.0"),
        .package(url: "https://github.com/maplibre/maplibre-gl-native-distribution", from: "6.20.0"),
    ],
    targets: [
        .target(
            name: "MapConductorForMapLibre",
            dependencies: [
                .product(name: "MapConductorCore", package: "ios-sdk-core"),
                .product(name: "MapLibre", package: "maplibre-gl-native-distribution"),
            ]
        ),
    ]
)
