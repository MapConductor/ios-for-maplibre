import Combine
import CoreGraphics
import CoreLocation
import Foundation
import MapConductorCore
import MapLibre
import QuartzCore
import Swift
import SwiftUI
import UIKit
import _Concurrency
import _StringProcessing
import _SwiftConcurrencyShims
public protocol MapLibreMapDesignTypeProtocol : MapConductorCore.MapDesignTypeProtocol where Self.Identifier == Swift.String {
  var styleJsonURL: Swift.String { get }
}
public typealias MapLibreMapDesignType = any MapConductorForMapLibre.MapLibreMapDesignTypeProtocol
public struct MapLibreDesign : MapConductorForMapLibre.MapLibreMapDesignTypeProtocol, Swift.Hashable {
  public let id: Swift.String
  public let styleJsonURL: Swift.String
  public let attributionRules: [MapConductorCore.AttributionRule]
  public init(id: Swift.String, styleJsonURL: Swift.String, attributionRules: [MapConductorCore.AttributionRule] = [])
  public func getValue() -> Swift.String
  public static let DemoTiles: MapConductorForMapLibre.MapLibreDesign
  public static let MapTilerTonerJa: MapConductorForMapLibre.MapLibreDesign
  public static let MapTilerTonerEn: MapConductorForMapLibre.MapLibreDesign
  public static let OsmBright: MapConductorForMapLibre.MapLibreDesign
  public static let OsmBrightEn: MapConductorForMapLibre.MapLibreDesign
  public static let OsmBrightJa: MapConductorForMapLibre.MapLibreDesign
  public static let MapTilerBasicEn: MapConductorForMapLibre.MapLibreDesign
  public static let OpenMapTiles: MapConductorForMapLibre.MapLibreDesign
  public static let MapTilerBasicJa: MapConductorForMapLibre.MapLibreDesign
  public static func == (a: MapConductorForMapLibre.MapLibreDesign, b: MapConductorForMapLibre.MapLibreDesign) -> Swift.Bool
  public typealias Identifier = Swift.String
  public func hash(into hasher: inout Swift.Hasher)
  public var hashValue: Swift.Int {
    get
  }
}
@_Concurrency.MainActor @preconcurrency public struct MapLibreMapView : SwiftUICore.View {
  @_Concurrency.MainActor @preconcurrency public init(state: MapConductorForMapLibre.MapLibreViewState, cameraRestriction: MapConductorCore.CameraRestriction? = nil, onMapLoaded: MapConductorCore.OnMapLoadedHandler<MapConductorForMapLibre.MapLibreViewState>? = nil, onMapClick: MapConductorCore.OnMapEventHandler? = nil, onMapLongClick: MapConductorCore.OnMapEventHandler? = nil, onCameraMoveStart: MapConductorCore.OnCameraMoveHandler? = nil, onCameraMove: MapConductorCore.OnCameraMoveHandler? = nil, onCameraMoveEnd: MapConductorCore.OnCameraMoveHandler? = nil, sdkInitialize: (() -> Swift.Void)? = nil, @MapConductorCore.MapViewContentBuilder content: @escaping () -> MapConductorCore.MapViewContent = { MapViewContent() })
  @_Concurrency.MainActor @preconcurrency public var body: some SwiftUICore.View {
    get
  }
  public typealias Body = @_opaqueReturnTypeOf("$s015MapConductorForA5Libre0adA4ViewV4bodyQrvp", 0) __
}
public typealias MapLibreActualMarker = MapLibre.MLNPointFeature
public typealias MapLibreActualPolyline = MapLibre.MLNPolyline
public typealias MapLibreActualCircle = MapLibre.MLNPolygon
public typealias MapLibreActualPolygon = MapLibre.MLNPolygon
final public class MapLibreViewState : MapConductorCore.MapViewState<MapConductorForMapLibre.MapLibreMapDesignType> {
  final public var mapViewHolder: MapConductorForMapLibre.MapLibreMapViewHolder? {
    get
  }
  override final public var mapDesignType: MapConductorForMapLibre.MapLibreMapDesignType {
    get
    set
  }
  public init(id: Swift.String, mapDesignType: MapConductorForMapLibre.MapLibreMapDesignType = MapLibreDesign.DemoTiles, cameraPosition: MapConductorCore.MapCameraPosition = .Default, uiSettings: MapConductorCore.MapUISettings = MapUISettings())
  convenience public init(mapDesignType: MapConductorForMapLibre.MapLibreMapDesignType = MapLibreDesign.OsmBright, cameraPosition: MapConductorCore.MapCameraPosition = .Default, uiSettings: MapConductorCore.MapUISettings = MapUISettings())
  override final public func getMapViewHolder() -> MapConductorCore.AnyMapViewHolder?
  @objc deinit
}
@_hasMissingDesignatedInitializers final public class MapLibreMapViewHolder : MapConductorCore.MapViewHolderProtocol {
  final public let mapView: MapLibre.MLNMapView
  final public let map: MapLibre.MLNMapView
  final public func toScreenOffset(position: any MapConductorCore.GeoPointProtocol) -> CoreFoundation.CGPoint?
  final public func fromScreenOffset(offset: CoreFoundation.CGPoint) async -> MapConductorCore.GeoPoint?
  final public func fromScreenOffsetSync(offset: CoreFoundation.CGPoint) -> MapConductorCore.GeoPoint?
  public typealias ActualMap = MapLibre.MLNMapView
  public typealias ActualMapView = MapLibre.MLNMapView
  @objc deinit
}
extension MapConductorForMapLibre.MapLibreMapView : Swift.Sendable {}
