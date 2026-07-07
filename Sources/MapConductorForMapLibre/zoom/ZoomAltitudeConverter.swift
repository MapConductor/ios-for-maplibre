import Foundation
import MapConductorCore

private let maplibreToGoogleZoomOffset = 1.0

extension ZoomAltitudeConverterProtocol where Self == MapLibreZoomAltitudeConverter {
    static var maplibre: MapLibreZoomAltitudeConverter { MapLibreZoomAltitudeConverter() }
}

class MapLibreZoomAltitudeConverter: ZoomAltitudeConverterProtocol {
    let zoom0Altitude: Double

    private let minZoomLevel: Double = 0.0
    private let maxZoomLevel: Double = 22.0
    private let minAltitude: Double = 100.0
    private let maxAltitude: Double = 50_000_000.0
    private let minCosLat: Double = 0.01
    private let minCosTilt: Double = 0.05

    init(zoom0Altitude: Double = 171_319_879.0) {
        self.zoom0Altitude = zoom0Altitude
    }

    /// GoogleZoom ≈ MapLibreSDK.zoom + 1.0
    static func maplibreZoomToGoogleZoom(_ zoom: Double) -> Double {
        (zoom + maplibreToGoogleZoomOffset).clamped(to: 0...22)
    }

    static func googleZoomToMaplibreZoom(_ zoom: Double) -> Double {
        (zoom - maplibreToGoogleZoomOffset).clamped(to: 0...22)
    }

    func zoomLevelToAltitude(zoomLevel: Double, latitude: Double, tilt: Double) -> Double {
        let googleZoom = Self.maplibreZoomToGoogleZoom(zoomLevel)
        let cosLat = max(abs(cos(latitude.clamped(to: -85...85) * .pi / 180)), minCosLat)
        let cosTilt = max(cos(tilt.clamped(to: 0...90) * .pi / 180), minCosTilt)
        let distance = (zoom0Altitude * cosLat) / pow(2.0, googleZoom)
        return (distance * cosTilt).clamped(to: minAltitude...maxAltitude)
    }

    func altitudeToZoomLevel(altitude: Double, latitude: Double, tilt: Double) -> Double {
        let cosLat = max(abs(cos(latitude.clamped(to: -85...85) * .pi / 180)), minCosLat)
        let cosTilt = max(cos(tilt.clamped(to: 0...90) * .pi / 180), minCosTilt)
        let distance = altitude.clamped(to: minAltitude...maxAltitude) / cosTilt
        let googleZoom = log2((zoom0Altitude * cosLat) / distance)
        return Self.googleZoomToMaplibreZoom(googleZoom)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
