import MapConductorCore
import MapLibre

@MainActor
final class MapLibrePolygonOverlayRenderer: AbstractPolygonOverlayRenderer<[MLNPolygonFeature]> {
    private weak var mapView: MLNMapView?
    private var style: MLNStyle?

    let polygonLayer: PolygonLayer
    private let polygonManager: PolygonManager<[MLNPolygonFeature]>

    init(
        mapView: MLNMapView?,
        polygonManager: PolygonManager<[MLNPolygonFeature]>,
        polygonLayer: PolygonLayer
    ) {
        self.mapView = mapView
        self.polygonManager = polygonManager
        self.polygonLayer = polygonLayer
        super.init()
    }

    func onStyleLoaded(_ style: MLNStyle) {
        self.style = style
        polygonLayer.ensureAdded(to: style)
    }

    func unbind() {
        if let style {
            polygonLayer.remove(from: style)
        }
        style = nil
        mapView = nil
    }

    /// 複数の穴が重なっている場合は結合（union）して重複を解消する。
    /// 他プロバイダ（ArcGIS/Mapbox/HERE/Google）と同じ `unionHoles()` を用いる。
    ///
    /// MapLibre は Polygon の inner ring で複数の穴を描けるが、偶奇規則なので重なった穴は
    /// 打ち消し合い、重なり部分が塗られてしまう。コンポーネント層（`Polygon`）のユニオンは
    /// state 1 インスタンスにつき 1 回きりで、頂点ドラッグ後の `state.holes` 差し替えには
    /// 追従しないため、android-for-maplibre と同じくここでも結合する。
    private func resolveHoles(_ state: PolygonState) -> PolygonState {
        state.holes.count > 1 ? state.unionHoles() : state
    }

    override func createPolygon(state: PolygonState) async -> [MLNPolygonFeature]? {
        let resolved = resolveHoles(state)
        let features = createMapLibrePolygons(
            id: resolved.id,
            points: resolved.points,
            geodesic: resolved.geodesic,
            fillColor: resolved.fillColor,
            strokeColor: resolved.strokeColor,
            strokeWidth: resolved.strokeWidth,
            zIndex: resolved.zIndex,
            holes: resolved.holes
        )
        return features.isEmpty ? nil : features
    }

    override func updatePolygonProperties(
        polygon: [MLNPolygonFeature],
        current: PolygonEntity<[MLNPolygonFeature]>,
        prev: PolygonEntity<[MLNPolygonFeature]>
    ) async -> [MLNPolygonFeature]? {
        return await createPolygon(state: current.state)
    }

    override func removePolygon(entity: PolygonEntity<[MLNPolygonFeature]>) async {
        // Removal is handled by redrawing all remaining polygons in onPostProcess.
    }

    override func onPostProcess() async {
        let features = polygonManager.allEntities().flatMap { $0.polygon ?? [] }
        polygonLayer.setFeatures(features)
    }
}
