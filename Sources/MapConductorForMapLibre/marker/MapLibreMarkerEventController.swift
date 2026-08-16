import CoreLocation
import Foundation
import MapConductorCore
import MapLibre
import UIKit

/// MapLibre のマーカーイベント。
///
/// タップの引き当て・ドラッグの状態遷移・パン抑止はすべてコアの
/// ``DefaultMarkerEventController`` が持つ。ここに残るのは
/// **MapLibre 固有の面の橋渡し**だけ。
///
/// 移行前はこのファイルが 84 行あり、ios-for-maplibre と ios-for-maptiler で
/// **import 文以外 1 文字も違わなかった**。
@MainActor
final class MapLibreMarkerEventController: DefaultMarkerEventController {
    init(mapView: MLNMapView?, markerController: MapLibreMarkerController) {
        super.init(
            surface: mapView.map { MLNMarkerDragSurface(mapView: $0) },
            host: MapLibreMarkerEventHost(markerController: markerController)
        )
    }

    /// UIKit のジェスチャをコアの状態へ写す。
    func handleLongPress(_ recognizer: UILongPressGestureRecognizer) -> Bool {
        guard let view = recognizer.view else { return false }
        return handleLongPress(
            state: MarkerDragGestureState(recognizer.state),
            at: recognizer.location(in: view)
        )
    }
}

/// `MLNMapView` をコアの ``MarkerDragSurface`` に適合させる。
@MainActor
private final class MLNMarkerDragSurface: MarkerDragSurface {
    private weak var mapView: MLNMapView?

    init(mapView: MLNMapView) { self.mapView = mapView }

    var isScrollEnabled: Bool {
        get { mapView?.isScrollEnabled ?? true }
        set { mapView?.isScrollEnabled = newValue }
    }

    func geoPoint(atScreenPoint point: CGPoint) -> GeoPoint? {
        guard let mapView else { return nil }
        let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
        return GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude, altitude: 0)
    }
}

/// MapLibreMarkerController をコアの ``MarkerEventHostProtocol`` に適合させる。
@MainActor
private final class MapLibreMarkerEventHost: MarkerEventHostProtocol {
    /// **weak で持つこと。** MapLibreMarkerController が eventController を強参照しており、
    /// ここを強参照にすると循環して地図を閉じても解放されない。
    private weak var markerController: MapLibreMarkerController?

    init(markerController: MapLibreMarkerController) { self.markerController = markerController }

    func markerId(atScreenPoint point: CGPoint) -> String? {
        markerController?.renderer.markerId(at: point)
    }

    func markerState(for id: String) -> MarkerState? {
        markerController?.getMarkerState(for: id)
    }

    func handleTiledMarkerTap(atScreenPoint point: CGPoint) -> Bool {
        markerController?.handleTiledMarkerTap(at: point) ?? false
    }

    func dispatchClick(state: MarkerState) { markerController?.dispatchClick(state: state) }
    func dispatchDragStart(state: MarkerState) { markerController?.dispatchDragStart(state: state) }
    func dispatchDrag(state: MarkerState) { markerController?.dispatchDrag(state: state) }
    func dispatchDragEnd(state: MarkerState) { markerController?.dispatchDragEnd(state: state) }
    func onUpdateInfoBubble(_ markerId: String) { markerController?.onUpdateInfoBubble(markerId) }
}

private extension MarkerDragGestureState {
    init(_ state: UIGestureRecognizer.State) {
        switch state {
        case .began: self = .began
        case .changed: self = .changed
        case .ended: self = .ended
        case .cancelled, .failed: self = .cancelled
        default: self = .other
        }
    }
}
