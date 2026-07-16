import Combine
import MapConductorCore
import SwiftUI
import UIKit

@objc(MCMapLibreReactNativeView)
public final class MapLibreReactNativeView: UIView {
    @objc public var eventHandler: ((String, [String: Any]) -> Void)?
    private let model = ReactNativeMapLibreModel()
    private lazy var host = UIHostingController(rootView: ReactNativeMapLibreRoot(model: model))
    private var generation: Int?
    private var pending: [MarkerState] = []

    public override init(frame: CGRect) {
        super.init(frame: frame)
        host.view.backgroundColor = .clear
        addSubview(host.view)
        model.emit = { [weak self] name, body in self?.eventHandler?(name, body) }
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func layoutSubviews() { super.layoutSubviews(); host.view.frame = bounds }

    @objc public func setCameraPosition(_ payload: [String: Any]) {
        if let camera = Self.camera(payload) { model.state.moveCameraTo(cameraPosition: camera) }
    }

    @objc public func setMarkerTilingOptions(_ payload: [String: Any]?) {
        model.tiling = MarkerTilingOptions(
            enabled: Self.number(payload?["enabled"])?.boolValue ?? true,
            debugTileOverlay: Self.number(payload?["debugTileOverlay"])?.boolValue ?? false,
            minMarkerCount: Self.number(payload?["minMarkerCount"])?.intValue ?? 2000,
            cacheSize: Self.number(payload?["cacheSize"])?.intValue ?? 8 * 1024 * 1024
        )
    }

    @objc public func moveCamera(_ payload: [String: Any], duration: Double) {
        if let camera = Self.camera(payload) {
            model.state.moveCameraTo(cameraPosition: camera, durationMillis: Int64(duration))
        }
    }

    @objc public func clearOverlays() { pending.removeAll(); model.markers = [] }
    @objc public func beginMarkerComposition(_ value: Int, icons: [[String: Any]]) {
        generation = value; pending.removeAll(keepingCapacity: true)
    }

    @objc public func appendMarkerComposition(_ value: Int, sequence: Int, payload: [String: Any]) {
        guard generation == value else { return }
        pending.append(contentsOf: Self.decode(payload, emit: model.emit))
        eventHandler?("markerCompositionBatchProcessed", ["generation": value, "sequence": sequence])
    }

    @objc public func commitMarkerComposition(_ value: Int) {
        guard generation == value else { return }
        model.markers = pending; pending.removeAll(); generation = nil
    }

    @objc public func updateMarker(_ payload: [String: Any]) {
        guard let marker = Self.marker(payload, emit: model.emit) else { return }
        var values = model.markers
        if let index = values.firstIndex(where: { $0.id == marker.id }) { values[index] = marker }
        else { values.append(marker) }
        model.markers = values
    }

    private static func decode(_ payload: [String: Any], emit: @escaping (String, [String: Any]) -> Void) -> [MarkerState] {
        guard let ids = payload["ids"] as? [String], let positions = payload["positions"] as? [NSNumber] else { return [] }
        let clickable = payload["clickable"] as? [NSNumber] ?? []
        let draggable = payload["draggable"] as? [NSNumber] ?? []
        let zIndex = payload["zIndex"] as? [NSNumber] ?? []
        return ids.indices.compactMap { index in
            let offset = index * 3
            guard positions.indices.contains(offset + 2) else { return nil }
            return makeMarker(
                id: ids[index],
                point: GeoPoint(latitude: positions[offset].doubleValue, longitude: positions[offset + 1].doubleValue, altitude: positions[offset + 2].doubleValue),
                clickable: clickable.indices.contains(index) ? clickable[index].boolValue : true,
                draggable: draggable.indices.contains(index) ? draggable[index].boolValue : false,
                zIndex: zIndex.indices.contains(index) ? zIndex[index].intValue : 0,
                emit: emit
            )
        }
    }

    private static func marker(_ payload: [String: Any], emit: @escaping (String, [String: Any]) -> Void) -> MarkerState? {
        guard let id = payload["id"] as? String, let position = payload["position"] as? [String: Any], let point = point(position) else { return nil }
        return makeMarker(id: id, point: point, clickable: number(payload["clickable"])?.boolValue ?? true, draggable: number(payload["draggable"])?.boolValue ?? false, zIndex: number(payload["zIndex"])?.intValue ?? 0, emit: emit)
    }

    private static func makeMarker(id: String, point: GeoPoint, clickable: Bool, draggable: Bool, zIndex: Int, emit: @escaping (String, [String: Any]) -> Void) -> MarkerState {
        MarkerState(position: point, id: id, icon: DefaultMarkerIcon(), clickable: clickable, draggable: draggable, zIndex: zIndex,
                    onClick: { emit("markerClick", ["markerId": $0.id]) },
                    onDragStart: { emit("markerDragStart", markerPayload($0)) },
                    onDrag: { emit("markerDrag", markerPayload($0)) },
                    onDragEnd: { emit("markerDragEnd", markerPayload($0)) })
    }

    private static func markerPayload(_ marker: MarkerState) -> [String: Any] { ["markerId": marker.id, "point": pointPayload(GeoPoint.from(position: marker.position))] }
    private static func point(_ value: [String: Any]) -> GeoPoint? {
        guard let lat = number(value["latitude"]), let lng = number(value["longitude"]) else { return nil }
        return GeoPoint(latitude: lat.doubleValue, longitude: lng.doubleValue, altitude: number(value["altitude"])?.doubleValue ?? 0)
    }
    private static func camera(_ value: [String: Any]) -> MapCameraPosition? {
        guard let position = value["position"] as? [String: Any], let point = point(position) else { return nil }
        return MapCameraPosition(position: point, zoom: number(value["zoom"])?.doubleValue ?? 0, bearing: number(value["bearing"])?.doubleValue ?? 0, tilt: number(value["tilt"])?.doubleValue ?? 0)
    }
    fileprivate static func pointPayload(_ point: GeoPoint) -> [String: Any] { ["latitude": point.latitude, "longitude": point.longitude, "altitude": point.altitude ?? 0] }
    private static func number(_ value: Any?) -> NSNumber? { value as? NSNumber }
}

private final class ReactNativeMapLibreModel: ObservableObject {
    let state = MapLibreViewState()
    @Published var markers: [MarkerState] = []
    @Published var tiling = MarkerTilingOptions.Default
    var emit: (String, [String: Any]) -> Void = { _, _ in }
}

private struct ReactNativeMapLibreRoot: View {
    @ObservedObject var model: ReactNativeMapLibreModel
    var body: some View {
        MapLibreMapView(state: model.state,
            onMapLoaded: { _ in model.emit("mapLoaded", [:]) },
            onMapClick: { model.emit("mapClick", ["point": MapLibreReactNativeView.pointPayload($0)]) },
            onMapLongClick: { model.emit("mapLongClick", ["point": MapLibreReactNativeView.pointPayload($0)]) },
            onCameraMoveStart: { model.emit("cameraMoveStart", ["cameraPosition": camera($0)]) },
            onCameraMove: { model.emit("cameraMove", ["cameraPosition": camera($0)]) },
            onCameraMoveEnd: { model.emit("cameraMoveEnd", ["cameraPosition": camera($0)]) },
            content: {
                var content = MapViewContent()
                content.markers = model.markers.map(Marker.init(state:))
                content.markerTilingOptions = model.tiling
                return content
            })
    }
    private func camera(_ value: MapCameraPosition) -> [String: Any] {
        ["position": MapLibreReactNativeView.pointPayload(GeoPoint.from(position: value.position)), "zoom": value.zoom, "bearing": value.bearing, "tilt": value.tilt]
    }
}
