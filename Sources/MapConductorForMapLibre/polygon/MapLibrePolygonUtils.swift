import CoreLocation
import MapConductorCore
import MapLibre
import UIKit

func createMapLibrePolygons(
    id: String,
    points: [GeoPointProtocol],
    geodesic: Bool,
    fillColor: UIColor,
    strokeColor: UIColor,
    strokeWidth: Double,
    zIndex: Int = 0,
    holes: [[GeoPointProtocol]] = []
) -> [MLNPolygonFeature] {
    let interpolated: [GeoPointProtocol] = (geodesic ? createInterpolatePoints(points, maxSegmentLength: 1000.0) : createLinearInterpolatePoints(points))
        .map { $0.normalize() }

    let outerRings = splitByMeridian(interpolated, geodesic: geodesic)
    let includeHoles = !holes.isEmpty && outerRings.count == 1

    let interiorPolygons: [MLNPolygon] = includeHoles ? holes.compactMap { holePoints in
        let interpolatedHole: [GeoPointProtocol] = (geodesic
            ? createInterpolatePoints(holePoints, maxSegmentLength: 1000.0)
            : createLinearInterpolatePoints(holePoints))
            .map { $0.normalize() }
        guard interpolatedHole.count >= 3 else { return nil }

        var ring = ensureClockwiseRing(interpolatedHole)
        if let first = ring.first, let last = ring.last,
           !(GeoPoint.from(position: first) == GeoPoint.from(position: last)) {
            ring.append(first)
        }
        guard ring.count >= 4 else { return nil }

        var coordinates = ring.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        return MLNPolygon(coordinates: &coordinates, count: UInt(coordinates.count))
    } : []

    return outerRings.enumerated().map { index, ringPoints in
        let normalizedRing: [GeoPointProtocol]
        if let first = ringPoints.first, let last = ringPoints.last, GeoPoint.from(position: first) == GeoPoint.from(position: last) {
            normalizedRing = ringPoints
        } else if let first = ringPoints.first {
            normalizedRing = ringPoints + [first]
        } else {
            normalizedRing = ringPoints
        }
        let coordinates = normalizedRing.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        var coords = coordinates
        let polygon = interiorPolygons.isEmpty
            ? MLNPolygonFeature(coordinates: &coords, count: UInt(coords.count))
            : MLNPolygonFeature(coordinates: &coords, count: UInt(coords.count), interiorPolygons: interiorPolygons)
        let fid = "polygon-\(id)-\(index)"
        polygon.identifier = fid as NSString
        polygon.attributes = [
            PolygonLayer.Prop.fillColor: fillColor,
            PolygonLayer.Prop.strokeColor: strokeColor,
            PolygonLayer.Prop.strokeWidth: strokeWidth,
            PolygonLayer.Prop.zIndex: zIndex,
            PolygonLayer.Prop.polygonId: id,
            "id": fid
        ]
        return polygon
    }
}
