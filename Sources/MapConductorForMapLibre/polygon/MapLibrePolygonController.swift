import CoreLocation
import MapConductorCore
import MapLibre

/// ポリゴンの状態を集めるのは `OverlayCollector`（`MapOverlayScope.polygonCollector`）で、
/// `bindOverlayCollector` がここへ `add(data:)` / `update(state:)` を流す。
/// コントローラは購読も差分も持たない。
///
/// 以前はここに `syncPolygons` という自前の差分ループがあったが、コレクタ移行で
/// 呼び出し元が無くなっていた（`updateContent` はコレクタに `sync` する）。
/// `latestStates` / `isStyleLoaded` / 個別購読もその名残だったので落とした。
@MainActor
final class MapLibrePolygonController: PolygonController<[MLNPolygonFeature], MapLibrePolygonOverlayRenderer> {
    private weak var mapView: MLNMapView?

    init(mapView: MLNMapView?) {
        self.mapView = mapView

        let polygonManager = PolygonManager<[MLNPolygonFeature]>()
        let layer = PolygonLayer(
            sourceId: "mapconductor-polygons-source-\(UUID().uuidString)",
            fillLayerId: "mapconductor-polygons-fill-\(UUID().uuidString)",
            lineLayerId: "mapconductor-polygons-line-\(UUID().uuidString)"
        )
        let renderer = MapLibrePolygonOverlayRenderer(
            mapView: mapView,
            polygonManager: polygonManager,
            polygonLayer: layer
        )

        super.init(polygonManager: polygonManager, renderer: renderer)
    }

    /// スタイルが載るたびに呼ばれる。捨てられたソース／レイヤを作り直してから、
    /// **マネージャ**を元に描き直す（`onPostProcess` が `allEntities()` を読む）。
    /// マップ側の `polygonCollector.flush()` も同じ集合を流し直すが、`add` は冪等。
    func onStyleLoaded(_ style: MLNStyle) {
        renderer.onStyleLoaded(style)
        Task { [weak self] in
            await self?.renderer.onPostProcess()
        }
    }

    func handleTap(at coordinate: CLLocationCoordinate2D) -> Bool {
        let position = GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude, altitude: 0)
        guard let hit = find(position: position) else { return false }
        let event = PolygonEvent(state: hit.state, clicked: position)
        dispatchClick(event: event)
        return true
    }

    func unbind() {
        renderer.unbind()
        mapView = nil
        destroy()
    }
}
