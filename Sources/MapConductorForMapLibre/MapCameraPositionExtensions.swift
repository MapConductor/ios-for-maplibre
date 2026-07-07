import CoreLocation
import Foundation
import MapLibre
import MapConductorCore

private let converter = MapLibreZoomAltitudeConverter()
private let negativeTiltTargetDistanceScale = 1.83
private let negativeTiltZoomOffsetAtMaxTilt = -0.9

// Holds the converted camera values ready for MLNMapView APIs.
// Analogous to Android's CameraPosition returned by MapCameraPosition.toCameraPosition().
struct MapLibreCameraState {
    let center: CLLocationCoordinate2D
    let zoom: Double
    let bearing: Double
    let tilt: Double
}

// Pairs a MapLibreCameraState with the original logical tilt so the negative-tilt
// shift can be reversed when reading the camera back from the map.
// Analogous to Android's MapLibreCameraStateSnapshot.
struct MapLibreCameraStateSnapshot {
    let state: MapLibreCameraState
    let logicalTilt: Double?

    func toMapCameraPosition(visibleRegion: VisibleRegion? = nil) -> MapCameraPosition {
        state.toMapCameraPosition(logicalTiltHint: logicalTilt, visibleRegion: visibleRegion)
    }
}

// MARK: - MapCameraPosition → MapLibreCameraState

extension MapCameraPosition {
    /// Converts to MapLibre camera values, applying the Google↔MapLibre zoom offset
    /// and negative-tilt target shift to match Android's MapCameraPosition.toCameraPosition().
    func toMapLibreCameraState() -> MapLibreCameraState {
        if tilt >= 0 {
            return MapLibreCameraState(
                center: CLLocationCoordinate2D(latitude: position.latitude, longitude: position.longitude),
                zoom: MapLibreZoomAltitudeConverter.googleZoomToMaplibreZoom(zoom),
                bearing: bearing,
                tilt: tilt
            )
        }

        // tilt < 0: MapLibre cannot represent upward pitch directly.
        // Move the ground target forward and render with abs(tilt) — mirrors Android workaround.
        let tiltAbsDeg = abs(tilt).clamped(to: 0...60)
        let tiltAbsRad = tiltAbsDeg * .pi / 180
        let maplibreZoomForAltitude = MapLibreZoomAltitudeConverter.googleZoomToMaplibreZoom(zoom)
        let altitude = converter.zoomLevelToAltitude(zoomLevel: maplibreZoomForAltitude, latitude: position.latitude, tilt: 0.0)
        let distanceForward = altitude * cos(tiltAbsRad) * tan(tiltAbsRad) * negativeTiltTargetDistanceScale
        let target = Spherical.computeOffset(origin: position, distance: distanceForward, heading: bearing)
        let adjustedZoom = zoom + negativeTiltZoomOffsetAtMaxTilt * (tiltAbsDeg / 60.0)

        return MapLibreCameraState(
            center: CLLocationCoordinate2D(latitude: target.latitude, longitude: target.longitude),
            zoom: MapLibreZoomAltitudeConverter.googleZoomToMaplibreZoom(adjustedZoom),
            bearing: bearing,
            tilt: tiltAbsDeg
        )
    }

    func toMapLibreCameraStateSnapshot() -> MapLibreCameraStateSnapshot {
        MapLibreCameraStateSnapshot(state: toMapLibreCameraState(), logicalTilt: tilt)
    }
}

// MARK: - MapLibreCameraState → MapCameraPosition

extension MapLibreCameraState {
    /// Reverses the conversion. Pass `logicalTiltHint` (the tilt that was originally set)
    /// to correctly recover position and zoom when the original tilt was negative.
    /// Analogous to Android's CameraPosition.toMapCameraPosition(logicalTiltHint).
    func toMapCameraPosition(logicalTiltHint: Double? = nil, visibleRegion: VisibleRegion? = nil) -> MapCameraPosition {
        let tiltAbsDeg = tilt.clamped(to: 0...60)

        guard let hint = logicalTiltHint, hint < 0.0, tiltAbsDeg > 0.0 else {
            return MapCameraPosition(
                position: GeoPoint(latitude: center.latitude, longitude: center.longitude, altitude: 0),
                zoom: MapLibreZoomAltitudeConverter.maplibreZoomToGoogleZoom(zoom),
                bearing: bearing,
                tilt: tilt,
                visibleRegion: visibleRegion
            )
        }

        // Recover original position and zoom from the shifted camera state.
        let tiltAbsRad = tiltAbsDeg * .pi / 180
        let shiftedCenter = GeoPoint(latitude: center.latitude, longitude: center.longitude, altitude: 0)

        let googleZoom = MapLibreZoomAltitudeConverter.maplibreZoomToGoogleZoom(zoom)
        let originalGoogleZoom = googleZoom - negativeTiltZoomOffsetAtMaxTilt * (tiltAbsDeg / 60.0)
        let originalMaplibreZoom = MapLibreZoomAltitudeConverter.googleZoomToMaplibreZoom(originalGoogleZoom)

        let altitude = converter.zoomLevelToAltitude(zoomLevel: originalMaplibreZoom, latitude: shiftedCenter.latitude, tilt: 0.0)
        let distanceBackward = altitude * cos(tiltAbsRad) * tan(tiltAbsRad) * negativeTiltTargetDistanceScale
        let originalPosition = Spherical.computeOffset(origin: shiftedCenter, distance: distanceBackward, heading: bearing + 180.0)

        return MapCameraPosition(
            position: originalPosition,
            zoom: originalGoogleZoom,
            bearing: bearing,
            tilt: -tiltAbsDeg,
            visibleRegion: visibleRegion
        )
    }
}

// MARK: - MLNMapView → MapCameraPosition

extension MLNMapView {
    func toMapCameraPosition(logicalTiltHint: Double? = nil, visibleRegion: VisibleRegion? = nil) -> MapCameraPosition {
        let state = MapLibreCameraState(
            center: centerCoordinate,
            zoom: zoomLevel,
            bearing: camera.heading,
            tilt: camera.pitch
        )
        return state.toMapCameraPosition(logicalTiltHint: logicalTiltHint, visibleRegion: visibleRegion)
    }
}
