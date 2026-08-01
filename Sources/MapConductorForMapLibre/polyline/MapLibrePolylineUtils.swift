import CoreLocation
import MapConductorCore
import MapLibre

func createMapLibreLines(
    id: String,
    points: [GeoPointProtocol],
    geodesic: Bool,
    strokeColor: UIColor,
    strokeWidth: Double,
    zIndex: Int = 0
) -> [MLNPolylineFeature] {
    // MapLibre GL accepts longitudes beyond +/-180, so an unwrapped (continuous-longitude)
    // path renders seamlessly across the antimeridian without splitting.
    let path = buildUnwrappedPolylinePath(points, geodesic: geodesic, maxSegmentLength: 1000.0)
    guard !path.isEmpty else { return [] }

    var coords = path.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    let feature = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
    let fid = "polyline-\(id)-0"
    feature.identifier = fid as NSString
    feature.attributes = [
        PolylineLayer.Prop.strokeColor: strokeColor,
        PolylineLayer.Prop.strokeWidth: strokeWidth,
        PolylineLayer.Prop.zIndex: zIndex,
        PolylineLayer.Prop.polylineId: id,
        "id": fid
    ]
    return [feature]
}
