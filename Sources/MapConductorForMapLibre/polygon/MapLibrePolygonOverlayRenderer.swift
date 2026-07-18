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

    override func createPolygon(state: PolygonState) async -> [MLNPolygonFeature]? {
        let resolved = state.holes.count > 1 ? state.unionHoles() : state
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
