import CoreLocation
import MapConductorCore
import MapLibre

/// ポリラインの状態を集めるのは `OverlayCollector`（`MapOverlayScope.polylineCollector`）で、
/// `bindOverlayCollector` がここへ `add(data:)` / `update(state:)` を流す。
/// コントローラは購読も差分も持たない。
///
/// 以前はここに `syncPolylines` という自前の差分ループがあったが、コレクタ移行で
/// 呼び出し元が無くなっていた（`updateContent` はコレクタに `sync` する）。
/// `latestStates` / `isStyleLoaded` / 個別購読もその名残だったので落とした。
@MainActor
final class MapLibrePolylineController: PolylineController<[MLNPolylineFeature], MapLibrePolylineOverlayRenderer> {
    private weak var mapView: MLNMapView?

    init(mapView: MLNMapView?) {
        self.mapView = mapView

        let polylineManager = PolylineManager<[MLNPolylineFeature]>()
        let layer = PolylineLayer(
            sourceId: "mapconductor-polylines-source-\(UUID().uuidString)",
            layerId: "mapconductor-polylines-layer-\(UUID().uuidString)"
        )
        let renderer = MapLibrePolylineOverlayRenderer(
            mapView: mapView,
            polylineManager: polylineManager,
            polylineLayer: layer
        )

        super.init(polylineManager: polylineManager, renderer: renderer)
    }

    /// スタイルが載るたびに呼ばれる。捨てられたソース／レイヤを作り直してから、
    /// **マネージャ**を元に描き直す（`onPostProcess` が `allEntities()` を読む）。
    /// マップ側の `polylineCollector.flush()` も同じ集合を流し直すが、`add` は冪等。
    func onStyleLoaded(_ style: MLNStyle) {
        renderer.onStyleLoaded(style)
        Task { [weak self] in
            await self?.renderer.onPostProcess()
        }
    }

    func handleTap(at coordinate: CLLocationCoordinate2D) -> Bool {
        let position = GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude, altitude: 0)
        guard let hit = findWithClosestPoint(position: position) else { return false }
        let event = PolylineEvent(state: hit.entity.state, clicked: hit.closestPoint)
        dispatchClick(event: event)
        return true
    }

    func unbind() {
        renderer.unbind()
        mapView = nil
        destroy()
    }
}
