@_spi(MapConductorDriver) import MapConductorCore
import MapLibre
import UIKit
import XCTest

@testable import MapConductorForMapLibre

/**
 The polyline tiles' raster layer stacks in the polyline band: over circles
 (and polygon tiles), under the natively drawn polylines and the markers,
 whichever is added first.

 Checked against a real `MLNMapView` loading a real (local, empty) style, as
 `MapLibreTiledOnAddedTests` does.
 */
@MainActor
final class MapLibrePolylineTileStackingTests: XCTestCase {
    private final class StyleWaiter: NSObject, MLNMapViewDelegate {
        private(set) var style: MLNStyle?
        var onLoad: ((MLNStyle) -> Void)?
        func mapView(_: MLNMapView, didFinishLoading style: MLNStyle) {
            self.style = style
            onLoad?(style)
        }
    }

    private var mapView: MLNMapView!
    private var waiter: StyleWaiter!
    private var styleURL: URL!

    override func setUp() async throws {
        styleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mc-polyline-stacking-\(UUID().uuidString).json")
        try """
        {"version": 8, "name": "stacking", "sources": {},
         "layers": [{"id": "background", "type": "background"}]}
        """.write(to: styleURL, atomically: true, encoding: .utf8)
        waiter = StyleWaiter()
        mapView = MLNMapView(frame: CGRect(x: 0, y: 0, width: 256, height: 256), styleURL: nil)
        mapView.delegate = waiter
    }

    override func tearDown() async throws {
        mapView = nil
        waiter = nil
        try? FileManager.default.removeItem(at: styleURL)
    }

    private func load() async -> MLNStyle {
        mapView.styleURL = styleURL
        for _ in 0..<500 where waiter.style == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return waiter.style!
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    /// Which kind each MapConductor layer is, bottom first.
    private func order(_ style: MLNStyle) -> [String] {
        style.layers.compactMap { layer -> String? in
            let id = layer.identifier
            if id.hasPrefix("mapconductor-raster-layer-\(CircleTiler.layerId)") { return "circle-tiles" }
            if id.hasPrefix("mapconductor-raster-layer-\(PolylineTiler.layerId)") { return "polyline-tiles" }
            if id.hasPrefix("mapconductor-raster-layer-\(PolygonTiler.layerId)") { return "polygon-tiles" }
            if id.hasPrefix("mapconductor-circles-layer-") { return id.hasSuffix("-stroke") ? nil : "circles" }
            if id.hasPrefix("mapconductor-polylines-layer-") { return "polylines" }
            return nil
        }
    }

    private func tiles(_ raster: MapLibreRasterLayerController) async {
        await raster.upsert(state: PolylineTiler.rasterLayerState(template: "http://127.0.0.1:1/pl/v1/{z}/{x}/{y}.png"))
        await raster.upsert(state: PolygonTiler.rasterLayerState(template: "http://127.0.0.1:1/pg/v1/{z}/{x}/{y}.png"))
        await raster.upsert(state: CircleTiler.rasterLayerState(template: "http://127.0.0.1:1/circle/v1/{z}/{x}/{y}.png"))
    }

    func testTilesAddedAfterTheNativeLayersGoUnderThePolylines() async {
        let circles = MapLibreCircleController(mapView: mapView)
        let polylines = MapLibrePolylineController(mapView: mapView)
        let raster = MapLibreRasterLayerController(mapView: mapView)
        waiter.onLoad = { style in
            circles.onStyleLoaded(style)
            polylines.onStyleLoaded(style)
            raster.onStyleLoaded(style)
        }
        let style = await load()
        await settle()
        await tiles(raster)
        await settle()
        XCTAssertEqual(order(style), ["polygon-tiles", "circle-tiles", "circles", "polyline-tiles", "polylines"])
        raster.unbind()
        polylines.unbind()
        circles.unbind()
    }

    func testTilesAddedFirstStayUnderThePolylinesAddedLater() async {
        let raster = MapLibreRasterLayerController(mapView: mapView)
        let circles = MapLibreCircleController(mapView: mapView)
        let polylines = MapLibrePolylineController(mapView: mapView)
        waiter.onLoad = { style in raster.onStyleLoaded(style) }
        let style = await load()
        await settle()
        await tiles(raster)
        await settle()
        polylines.onStyleLoaded(style)
        circles.onStyleLoaded(style)
        await settle()
        XCTAssertEqual(order(style), ["polygon-tiles", "circle-tiles", "circles", "polyline-tiles", "polylines"])
        // A new template (in-place change) re-adds the tile layer: still in its place.
        await raster.upsert(state: PolylineTiler.rasterLayerState(template: "http://127.0.0.1:1/pl/v2/{z}/{x}/{y}.png"))
        await settle()
        XCTAssertEqual(order(style), ["polygon-tiles", "circle-tiles", "circles", "polyline-tiles", "polylines"])
        raster.unbind()
        polylines.unbind()
        circles.unbind()
    }

    func testTiledCirclesStayOutOfNativeFeaturesAfterStyleReload() async {
        let circles = MapLibreCircleController(mapView: mapView)
        let raster = MapLibreRasterLayerController(mapView: mapView)
        let tiler = CircleTiler(options: CircleTilingOptions(minCircleCount: 1))
        tiler.onTemplate = { template, tileSize in
            if let template {
                await raster.upsert(state: CircleTiler.rasterLayerState(template: template, tileSize: tileSize))
            } else {
                await raster.removeById(CircleTiler.layerId)
            }
        }
        circles.tiler = tiler
        waiter.onLoad = { style in
            circles.onStyleLoaded(style)
            raster.onStyleLoaded(style)
        }
        let style = await load()
        await settle()
        let state = CircleState(center: GeoPoint(latitude: 42, longitude: -71), radiusMeters: 20, id: "tiled")
        await circles.add(data: [state])
        XCTAssertNotNil(circles.circleManager.getEntity(state.id))
        XCTAssertNil(circles.circleManager.getEntity(state.id)?.circle)
        XCTAssertTrue(style.layers.contains { $0.identifier.contains(CircleTiler.layerId) })
        circles.onStyleLoaded(style)
        await settle()
        XCTAssertNil(circles.circleManager.getEntity(state.id)?.circle)
        XCTAssertEqual(circles.find(position: state.center)?.state.id, state.id)
        await circles.clear()
        XCTAssertFalse(style.layers.contains { $0.identifier.contains(CircleTiler.layerId) })
        circles.unbind()
        raster.unbind()
    }

}
