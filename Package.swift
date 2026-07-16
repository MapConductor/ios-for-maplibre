// swift-tools-version: 5.9
import Foundation
import PackageDescription

let frameworkLibraryType: Product.Library.LibraryType? =
    ProcessInfo.processInfo.environment["MAPCONDUCTOR_BUILD_XCFRAMEWORK"] == "1" ? .dynamic : nil
let usingLocalCore = FileManager.default.fileExists(atPath: "../ios-sdk-core/Package.swift")
let coreDependency: Package.Dependency = usingLocalCore
    ? .package(path: "../ios-sdk-core")
    : .package(url: "https://github.com/MapConductor/ios-sdk-core", from: "1.1.4")

let package = Package(
    name: "mapconductor-for-maplibre",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "MapConductorForMapLibre",
            type: frameworkLibraryType,
            targets: ["MapConductorForMapLibre"]
        ),
    ],
    dependencies: [
        coreDependency,
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
