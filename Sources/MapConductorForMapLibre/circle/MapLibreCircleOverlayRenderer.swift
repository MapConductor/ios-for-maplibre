import MapConductorCore
import MapLibre
import UIKit

@MainActor
final class MapLibreCircleOverlayRenderer: AbstractCircleOverlayRenderer<MLNPolygonFeature> {
    private weak var mapView: MLNMapView?
    private var style: MLNStyle?

    let circleLayer: CircleLayer
    private let circleManager: CircleManager<MLNPolygonFeature>

    init(
        mapView: MLNMapView?,
        circleManager: CircleManager<MLNPolygonFeature>,
        circleLayer: CircleLayer
    ) {
        self.mapView = mapView
        self.circleManager = circleManager
        self.circleLayer = circleLayer
        super.init()
    }

    func onStyleLoaded(_ style: MLNStyle) {
        self.style = style
        circleLayer.ensureAdded(to: style)
    }

    func unbind() {
        if let style {
            circleLayer.remove(from: style)
        }
        style = nil
        mapView = nil
    }

    override func createCircle(state: CircleState) async -> MLNPolygonFeature? {
        makeFeature(for: state)
    }

    override func updateCircleProperties(
        circle: MLNPolygonFeature,
        current: CircleEntity<MLNPolygonFeature>,
        prev: CircleEntity<MLNPolygonFeature>
    ) async -> MLNPolygonFeature? {
        makeFeature(for: current.state)
    }

    override func removeCircle(entity: CircleEntity<MLNPolygonFeature>) async {
        // Removal is handled by redrawing all remaining circles in onPostProcess.
    }

    override func onPostProcess() async {
        let features = circleManager.allEntities().compactMap { entity -> MLNPolygonFeature? in
            let updated = makeFeature(for: entity.state)
            entity.circle = updated
            return updated
        }
        circleLayer.setFeatures(features)
    }

    /// The core `circleToRing` generates the ring. The ring is unwrapped (continuous
    /// longitudes around the center), and MapLibre GL accepts longitudes beyond +/-180, so a
    /// circle crossing the antimeridian renders as a single polygon without splitting.
    private func makeFeature(for state: CircleState) -> MLNPolygonFeature {
        let ring = closeRing(circleToRing(
            center: state.center,
            radiusMeters: state.radiusMeters,
            geodesic: state.geodesic
        ))
        var coords = ring.isEmpty
            ? [CLLocationCoordinate2D(latitude: state.center.latitude, longitude: state.center.longitude)]
            : ring.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let feature = MLNPolygonFeature(coordinates: &coords, count: UInt(coords.count))
        feature.identifier = "circle-\(state.id)" as NSString
        feature.attributes = [
            CircleLayer.Prop.fillColor: state.fillColor,
            CircleLayer.Prop.strokeColor: state.strokeColor,
            CircleLayer.Prop.strokeWidth: state.strokeWidth,
            CircleLayer.Prop.circleId: state.id
        ]
        return feature
    }
}
