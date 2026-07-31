import CoreGraphics
import CoreLocation
import MapLibre
import MapConductorCore

public final class MapLibreMapViewHolder: MapViewHolderProtocol {
    public let mapView: MLNMapView
    public let map: MLNMapView

    init(mapView: MLNMapView) {
        self.mapView = mapView
        self.map = mapView
    }

    public func toScreenOffset(position: GeoPointProtocol) -> CGPoint? {
        let coordinate = CLLocationCoordinate2D(latitude: position.latitude, longitude: position.longitude)
        return mapView.convert(coordinate, toPointTo: mapView)
    }

    public func fromScreenOffset(offset: CGPoint) async -> GeoPoint? {
        fromScreenOffsetSync(offset: offset)
    }

    public func fromScreenOffsetSync(offset: CGPoint) -> GeoPoint? {
        let coordinate = mapView.convert(offset, toCoordinateFrom: mapView)
        return GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude, altitude: 0)
    }
}
