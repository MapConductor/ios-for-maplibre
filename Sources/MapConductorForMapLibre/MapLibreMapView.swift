import Combine
import Foundation
import MapConductorCore
import MapLibre
import SwiftUI
import UIKit

public struct MapLibreMapView: View {
    @ObservedObject private var state: MapLibreViewState
    private let handlers: MapViewHandlers<MapLibreViewState>
    private let cameraRestriction: CameraRestriction?
    private let content: () -> MapViewContent

    public init(
        state: MapLibreViewState,
        cameraRestriction: CameraRestriction? = nil,
        onMapLoaded: OnMapLoadedHandler<MapLibreViewState>? = nil,
        onMapClick: OnMapEventHandler? = nil,
        onMapLongClick: OnMapEventHandler? = nil,
        onCameraMoveStart: OnCameraMoveHandler? = nil,
        onCameraMove: OnCameraMoveHandler? = nil,
        onCameraMoveEnd: OnCameraMoveHandler? = nil,
        sdkInitialize: (() -> Void)? = nil,
        @MapViewContentBuilder content: @escaping () -> MapViewContent = { MapViewContent() }
    ) {
        self.state = state
        self.handlers = MapViewHandlers(
            onMapLoaded: onMapLoaded,
            onMapClick: onMapClick,
            onMapLongClick: onMapLongClick,
            onCameraMoveStart: onCameraMoveStart,
            onCameraMove: onCameraMove,
            onCameraMoveEnd: onCameraMoveEnd,
            sdkInitialize: sdkInitialize
        )
        self.cameraRestriction = cameraRestriction
        self.content = content
    }

    public var body: some View {
        // The provider's registry is in scope only while content is being assembled —
        // the same window in which Compose provides `LocalMapServiceRegistry` around the
        // content lambda. Bracketing the pass lets a removed plugin be noticed.
        let support = state.serviceRegistry.get(MarkerRenderingSupportKey.self)
        support?.beginContentPass()
        let mapContent = MapServiceRegistryScope.with(state.serviceRegistry) { content() }
        support?.endContentPass()
        return MapViewBase(
            attributionRules: state.mapDesignType.attributionRules,
            camera: state.cameraPosition,
            content: mapContent
        ) {
            MapLibreMapViewRepresentable(
                state: state,
                handlers: handlers,
                cameraRestriction: cameraRestriction,
                content: mapContent
            )
        }
    }
}
private struct MapLibreMapViewRepresentable: UIViewRepresentable {
    @ObservedObject var state: MapLibreViewState
    let handlers: MapViewHandlers<MapLibreViewState>
    let cameraRestriction: CameraRestriction?
    let content: MapViewContent

    // 地図の組み立てと結線は `MapLibreMapHost` が持つ。ここは SwiftUI のライフサイクルを
    // ホストの呼び出しへ翻訳するだけにして、React Native のような非 SwiftUI ホストと
    // まったく同じ経路を通るようにしている。
    func makeCoordinator() -> MapLibreMapHost {
        MapLibreMapHost(state: state, handlers: handlers)
    }

    func makeUIView(context: Context) -> MLNMapView {
        context.coordinator.makeMapView(cameraRestriction: cameraRestriction, content: content)
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {
        context.coordinator.syncNativeViewSettings(cameraRestriction: cameraRestriction)
        MCLog.map("MapLibreMapView.updateUIView updateContent markers=\(content.markers.count) bubbles=\(content.infoBubbles.count)")
        context.coordinator.updateContent(content)
        context.coordinator.updateInfoBubbleLayouts()
    }

    static func dismantleUIView(_ uiView: MLNMapView, coordinator: MapLibreMapHost) {
        coordinator.unbind()
        uiView.delegate = nil
    }
}
