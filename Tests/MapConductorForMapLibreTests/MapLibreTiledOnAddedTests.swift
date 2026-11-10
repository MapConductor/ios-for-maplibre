@_spi(MapConductorDriver) import MapConductorCore
import MapLibre
import UIKit
import XCTest

@testable import MapConductorForMapLibre

/**
 Overlays drawn as raster tiles report `onAdded` only once their tile layer is
 in the style the map shows.

 Without a style (the first one still loading, or a new map design replacing
 it) there is nowhere to add the layer: it goes on in `onStyleLoaded`. Markers
 tiled and polygon tiles upserted in that window used to report `onAdded` right
 away, so an app hiding its loading screen on `onAdded` showed an empty map.

 Checked against a real `MLNMapView` loading real (local, empty) styles, since
 the question is when `MLNMapView.style` is there.
 */
@MainActor
final class MapLibreTiledOnAddedTests: XCTestCase {
    private final class StyleWaiter: NSObject, MLNMapViewDelegate {
        private(set) var style: MLNStyle?
        private(set) var loads = 0
        /// Hands the style over inside the delegate call, as `MapLibreMapHost`
        /// does. Handed over later, the map already shows the new style while
        /// the marker layer still points at the old one's source, and writing
        /// to it took the test process down. The app never has that window.
        var onLoad: ((MLNStyle) -> Void)?

        func mapView(_: MLNMapView, didFinishLoading style: MLNStyle) {
            self.style = style
            loads += 1
            onLoad?(style)
        }
    }

    private var mapView: MLNMapView!
    private var waiter: StyleWaiter!
    private var styleURLs: [URL] = []

    override func setUp() async throws {
        styleURLs = try ["first", "second"].map { name in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("mc-onadded-\(name)-\(UUID().uuidString).json")
            let json = """
            {"version": 8, "name": "\(name)", "sources": {},
             "layers": [{"id": "background", "type": "background"}]}
            """
            try json.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        waiter = StyleWaiter()
        mapView = MLNMapView(frame: CGRect(x: 0, y: 0, width: 256, height: 256), styleURL: nil)
        mapView.delegate = waiter
    }

    override func tearDown() async throws {
        mapView = nil
        waiter = nil
        for url in styleURLs { try? FileManager.default.removeItem(at: url) }
    }

    private func load(_ url: URL) async -> MLNStyle {
        let loadsBefore = waiter.loads
        mapView.styleURL = url
        for _ in 0..<500 where waiter.loads == loadsBefore {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(waiter.loads, loadsBefore, "style loaded")
        return waiter.style!
    }

    /// Puts the map in the state it is in while a new design loads -- no
    /// style -- and keeps it there: the address never answers. A local style
    /// would finish loading inside the next `await`, before anything could be
    /// checked against its absence.
    private func startLoadingANewDesignThatHangs() {
        mapView.styleURL = URL(string: "http://127.0.0.1:1/never.json")
        XCTAssertNil(mapView.style, "no style while the new design loads")
    }

    /// Lets queued main-actor tasks run.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    private func hasLayer(_ style: MLNStyle, prefix: String) -> Bool {
        style.layers.contains { $0.identifier.hasPrefix(prefix) }
    }

    private func markers(_ count: Int, onAdded: @escaping OnMarkerEventHandler) -> [MarkerState] {
        (0..<count).map { i in
            MarkerState(
                position: GeoPoint(latitude: 35.6 + Double(i) * 0.001, longitude: 139.7, altitude: 0),
                id: "m\(i)",
                onAdded: onAdded
            )
        }
    }

    func testMarkersTiledWhileANewDesignLoadsWaitForTheirTileLayer() async {
        let controller = MapLibreMarkerController(mapView: mapView) { _ in }
        controller.tilingOptions = MarkerTilingOptions(minMarkerCount: 1)
        waiter.onLoad = { controller.onStyleLoaded($0) }
        _ = await load(styleURLs[0])

        var added: [String] = []
        startLoadingANewDesignThatHangs()

        await controller.add(data: markers(3, onAdded: { added.append($0.id) }))
        await settle()
        XCTAssertEqual(added, [], "the tile layer is not on the map yet")

        let second = await load(styleURLs[1])
        await settle()
        XCTAssertTrue(hasLayer(second, prefix: "mapconductor-tile-markers-layer-"), "tile layer in the new style")
        XCTAssertEqual(added.sorted(), ["m0", "m1", "m2"], "reported once the layer went on")

        // Another style load does not report them again.
        _ = await load(styleURLs[0])
        await settle()
        XCTAssertEqual(added.count, 3)
        controller.unbind()
    }

    func testMarkersTiledBeforeTheFirstStyleWaitForTheirTileLayer() async {
        let controller = MapLibreMarkerController(mapView: mapView) { _ in }
        controller.tilingOptions = MarkerTilingOptions(minMarkerCount: 1)
        waiter.onLoad = { controller.onStyleLoaded($0) }

        var added: [String] = []
        await controller.add(data: markers(3, onAdded: { added.append($0.id) }))
        await settle()
        XCTAssertEqual(added, [], "no style, so no tile layer yet")

        let style = await load(styleURLs[0])
        await settle()
        XCTAssertTrue(hasLayer(style, prefix: "mapconductor-tile-markers-layer-"))
        XCTAssertEqual(added.sorted(), ["m0", "m1", "m2"])
        controller.unbind()
    }

    func testMarkersRemovedBeforeTheStyleLoadsAreNotReported() async {
        let controller = MapLibreMarkerController(mapView: mapView) { _ in }
        controller.tilingOptions = MarkerTilingOptions(minMarkerCount: 1)
        waiter.onLoad = { controller.onStyleLoaded($0) }
        _ = await load(styleURLs[0])

        var added: [String] = []
        startLoadingANewDesignThatHangs()
        await controller.add(data: markers(3, onAdded: { added.append($0.id) }))
        // The app emptied the list while the style loaded.
        await controller.add(data: [])

        _ = await load(styleURLs[1])
        await settle()
        XCTAssertEqual(added, [])
        controller.unbind()
    }

    func testMarkersTiledWithTheStyleShowingAreReportedRightAway() async {
        let controller = MapLibreMarkerController(mapView: mapView) { _ in }
        controller.tilingOptions = MarkerTilingOptions(minMarkerCount: 1)
        waiter.onLoad = { controller.onStyleLoaded($0) }
        let style = await load(styleURLs[0])

        var added: [String] = []
        await controller.add(data: markers(2, onAdded: { added.append($0.id) }))
        await settle()
        XCTAssertTrue(hasLayer(style, prefix: "mapconductor-tile-markers-layer-"))
        XCTAssertEqual(added.sorted(), ["m0", "m1"])
        controller.unbind()
    }

    func testPolygonTilesUpsertedBeforeTheFirstStyleReturnOnceTheLayerIsOn() async {
        let controller = MapLibreRasterLayerController(mapView: mapView)
        waiter.onLoad = { controller.onStyleLoaded($0) }
        var returned = false
        Task {
            await controller.upsert(state: PolygonTiler.rasterLayerState(template: "http://127.0.0.1:1/{z}/{x}/{y}.png"))
            returned = true
        }
        await settle()
        XCTAssertFalse(returned, "no style to put the layer in yet")

        let style = await load(styleURLs[0])
        await settle()
        XCTAssertTrue(returned)
        XCTAssertTrue(hasLayer(style, prefix: "mapconductor-raster-layer-\(PolygonTiler.layerId)"))
        controller.unbind()
    }

    func testPolygonTilesUpsertedWhileANewDesignLoadsReturnOnceTheLayerIsOn() async {
        let controller = MapLibreRasterLayerController(mapView: mapView)
        waiter.onLoad = { controller.onStyleLoaded($0) }
        _ = await load(styleURLs[0])

        startLoadingANewDesignThatHangs()
        var returned = false
        Task {
            await controller.upsert(state: PolygonTiler.rasterLayerState(template: "http://127.0.0.1:1/{z}/{x}/{y}.png"))
            returned = true
        }
        await settle()
        XCTAssertFalse(returned, "the layer was dropped with the outgoing style")

        let second = await load(styleURLs[1])
        await settle()
        XCTAssertTrue(returned)
        XCTAssertTrue(hasLayer(second, prefix: "mapconductor-raster-layer-\(PolygonTiler.layerId)"))

        // With the style showing, an upsert returns straight away.
        await controller.upsert(state: PolygonTiler.rasterLayerState(template: "http://127.0.0.1:1/v2/{z}/{x}/{y}.png"))
        controller.unbind()
    }

    func testUnbindReleasesAWaitingUpsert() async {
        let controller = MapLibreRasterLayerController(mapView: mapView)
        waiter.onLoad = { controller.onStyleLoaded($0) }
        var returned = false
        Task {
            await controller.upsert(state: PolygonTiler.rasterLayerState(template: "http://127.0.0.1:1/{z}/{x}/{y}.png"))
            returned = true
        }
        await settle()
        controller.unbind()
        await settle()
        XCTAssertTrue(returned)
    }
}
