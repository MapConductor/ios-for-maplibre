import CoreLocation
import Foundation
import MapConductorCore
import MapLibre
import UIKit

@MainActor
final class MapLibreMarkerEventController {
    private weak var mapView: MLNMapView?
    private let markerController: MapLibreMarkerController

    private var draggingMarkerId: String?
    /// Panning is suppressed while a marker is dragged; remember what it was so
    /// an app that set `uiSettings.scrollGesture = false` keeps that setting.
    private var scrollEnabledBeforeDrag: Bool?

    init(mapView: MLNMapView?, markerController: MapLibreMarkerController) {
        self.mapView = mapView
        self.markerController = markerController
    }

    func handleTap(at point: CGPoint) -> Bool {
        // Check native symbol markers first.
        if let markerId = markerController.renderer.markerId(at: point),
           let state = markerController.getMarkerState(for: markerId),
           state.clickable {
            markerController.dispatchClick(state: state)
            return true
        }
        // Fall back to geographic proximity search for tile-rendered markers.
        return markerController.handleTiledMarkerTap(at: point)
    }

    func handleLongPress(_ recognizer: UILongPressGestureRecognizer) -> Bool {
        guard let mapView else { return false }
        let point = recognizer.location(in: mapView)

        switch recognizer.state {
        case .began:
            guard let markerId = markerController.renderer.markerId(at: point),
                  let state = markerController.getMarkerState(for: markerId),
                  state.draggable else { return false }
            draggingMarkerId = markerId
            scrollEnabledBeforeDrag = mapView.isScrollEnabled
            mapView.isScrollEnabled = false
            markerController.dispatchDragStart(state: state)
            markerController.onUpdateInfoBubble(markerId)
            return true
        case .changed:
            guard let markerId = draggingMarkerId,
                  let state = markerController.getMarkerState(for: markerId) else { return false }
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            state.position = GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude, altitude: 0)
            markerController.dispatchDrag(state: state)
            markerController.onUpdateInfoBubble(markerId)
            return true
        case .ended:
            guard let markerId = draggingMarkerId,
                  let state = markerController.getMarkerState(for: markerId) else {
                mapView.isScrollEnabled = scrollEnabledBeforeDrag ?? true; scrollEnabledBeforeDrag = nil
                draggingMarkerId = nil
                return false
            }
            markerController.dispatchDragEnd(state: state)
            mapView.isScrollEnabled = scrollEnabledBeforeDrag ?? true; scrollEnabledBeforeDrag = nil
            draggingMarkerId = nil
            markerController.onUpdateInfoBubble(markerId)
            return true
        case .cancelled, .failed:
            let wasDragging = draggingMarkerId != nil
            mapView.isScrollEnabled = scrollEnabledBeforeDrag ?? true; scrollEnabledBeforeDrag = nil
            draggingMarkerId = nil
            return wasDragging
        default:
            return draggingMarkerId != nil
        }
    }

    func unbind() {
        mapView?.isScrollEnabled = scrollEnabledBeforeDrag ?? true; scrollEnabledBeforeDrag = nil
        mapView = nil
        draggingMarkerId = nil
    }
}
