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
    private let style: MapViewStyle?
    private let onStyleDiagnostics: (([String]) -> Void)?
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
        /// How the map looks, when the app states it rather than naming a
        /// design. `MapConductorVectorStyle` builds one; what happens
        /// underneath depends on this backend and the app does not have to
        /// know.
        style: MapViewStyle? = nil,
        onStyleDiagnostics: (([String]) -> Void)? = nil,
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
        self.style = style
        self.onStyleDiagnostics = onStyleDiagnostics
        self.content = content
    }

    public var body: some View {
        // The provider's registry is in scope only while content is being assembled —
        // the same window in which Compose provides `LocalMapServiceRegistry` around the
        // content lambda. Bracketing the pass lets a removed plugin be noticed.
        let support = state.serviceRegistry.get(MarkerRenderingSupportKey.self)
        support?.beginContentPass()
        let contentStart = DispatchTime.now().uptimeNanoseconds
        let mapContent = MapServiceRegistryScope.with(state.serviceRegistry) { content() }
        let contentMs = Double(DispatchTime.now().uptimeNanoseconds - contentStart) / 1e6
        if contentMs > 50 {
            // アプリ側の content クロージャが重い場合はここに出る。body は
            // カメラが動くたびに再評価されるので、ここの重さは操作の重さになる。
            MCLog.probe("SLOW content() \(Int(contentMs))ms markers=\(mapContent.markers.count)")
        }
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
                style: style,
                onStyleDiagnostics: onStyleDiagnostics,
                content: mapContent
            )
        }
    }
}
private struct MapLibreMapViewRepresentable: UIViewRepresentable {
    @ObservedObject var state: MapLibreViewState
    let handlers: MapViewHandlers<MapLibreViewState>
    let cameraRestriction: CameraRestriction?
    let style: MapViewStyle?
    let onStyleDiagnostics: (([String]) -> Void)?
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
        // Every evaluation of the app's `body` lands here; most calls do
        // nothing. See `MapViewStyleHost.apply`.
        context.coordinator.applyStyle(style, onDiagnostics: onStyleDiagnostics)
        context.coordinator.syncNativeViewSettings(cameraRestriction: cameraRestriction)
        MCLog.map("MapLibreMapView.updateUIView updateContent markers=\(content.markers.count) bubbles=\(content.infoBubbles.count)")
        context.coordinator.updateContent(content)
        context.coordinator.updateInfoBubbleLayouts()
    }

    static func dismantleUIView(_ uiView: MLNMapView, coordinator: MapLibreMapHost) {
        coordinator.disposeStyle()
        coordinator.unbind()
        uiView.delegate = nil
    }
}
