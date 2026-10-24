// swift-tools-version: 5.9
import Foundation
import PackageDescription

let frameworkLibraryType: Product.Library.LibraryType? =
    ProcessInfo.processInfo.environment["MAPCONDUCTOR_BUILD_XCFRAMEWORK"] == "1" ? .dynamic : nil
let usingLocalCore = FileManager.default.fileExists(atPath: "../ios-sdk-core/Package.swift")
let coreDependency: Package.Dependency = usingLocalCore
    ? .package(path: "../ios-sdk-core")
    : .package(url: "https://github.com/MapConductor/ios-sdk-core", from: "1.3.2")

let package = Package(
    name: "mapconductor-for-maplibre",
    platforms: [
        // See ios-sdk-core/Package.swift's comment: "15.0" must not be used here.
        .iOS("15.1"),
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
        .package(url: "https://github.com/maplibre/maplibre-gl-native-distribution", from: "6.31.0"),
    ],
    targets: [
        // MapLibre's style API raises Objective-C exceptions, which Swift
        // cannot catch. See the header.
        .target(name: "CMapLibreStyleTry"),
        .target(
            name: "MapConductorForMapLibre",
            dependencies: [
                "CMapLibreStyleTry",
                .product(name: "MapConductorCore", package: "ios-sdk-core"),
                .product(name: "MapLibre", package: "maplibre-gl-native-distribution"),
            ]
        ),
        // The vector style adapter is the one part of this provider that can
        // be checked without a map on screen: a style layer is a real object
        // before it is added to a style, so what reaches its properties can
        // be read back.
        .testTarget(
            name: "MapConductorForMapLibreTests",
            dependencies: ["MapConductorForMapLibre"]
        ),
    ]
)
