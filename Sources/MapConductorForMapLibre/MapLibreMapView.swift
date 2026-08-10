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

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, handlers: handlers)
    }

    func makeUIView(context: Context) -> MLNMapView {
        if let sdkInitialize = handlers.sdkInitialize {
            Coordinator.runOnce(sdkInitialize)
        }
        let mapView = MLNMapView(frame: .zero)
        // Install the delegate before assigning the style URL. Cached styles can
        // finish loading quickly, and missing that callback leaves overlays waiting.
        mapView.delegate = context.coordinator
        // Prefer full-resolution rendering on Retina displays.
        // (MapLibre uses the view's pixel ratio for both tiles and symbols.)
        mapView.contentScaleFactor = UIScreen.main.scale
        mapView.layer.contentsScale = UIScreen.main.scale
        if let styleURL = URL(string: state.mapDesignType.styleJsonURL) {
            mapView.styleURL = styleURL
        }
        // Prefetch parent tiles for smoother zoom, and cache rendered tiles.
        // Marker raster tiles are safe to cache because their URL carries a
        // `version` that is bumped whenever markers change (see
        // MapLibreMarkerController.updateTileLayer), so a cached tile can never
        // be stale — while avoiding re-rendering identical marker PNG tiles on
        // every zoom in/out.
        mapView.prefetchesTiles = true
        mapView.tileCacheEnabled = true
        mapView.isScrollEnabled = state.uiSettings.scrollGesture
        mapView.isZoomEnabled = state.uiSettings.zoomGesture
        mapView.isRotateEnabled = state.uiSettings.rotateGesture
        mapView.isPitchEnabled = state.uiSettings.tiltGesture
        let initialCameraState = state.cameraPosition.toMapLibreCameraState()
        mapView.setCenter(
            initialCameraState.center,
            zoomLevel: initialCameraState.zoom,
            direction: initialCameraState.bearing,
            animated: false
        )
        let initialCamera = mapView.camera
        initialCamera.pitch = initialCameraState.tilt
        mapView.setCamera(initialCamera, animated: false)

        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMapTap(_:)))
        tapGesture.cancelsTouchesInView = false
        mapView.addGestureRecognizer(tapGesture)

        let longPressGesture = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleMarkerLongPress(_:))
        )
        longPressGesture.minimumPressDuration = 0.2
        mapView.addGestureRecognizer(longPressGesture)

        context.coordinator.attachInfoBubbleContainer(to: mapView)
        context.coordinator.mapView = mapView
        context.coordinator.bind(state: state, mapView: mapView)
        // android-sdk の `MapLibreMapView.kt` がコントローラ生成直後に
        // `cameraRestriction?.let { controller.setCameraRestriction(it) }` するのと同じ位置。
        context.coordinator.applyCameraRestriction(cameraRestriction)
        // Ensure overlay controllers subscribe immediately (before the first updateUIView),
        // so early UI actions (e.g. tapping animation buttons) are not missed.
        MCLog.map("MapLibreMapView.makeUIView updateContent markers=\(content.markers.count) bubbles=\(content.infoBubbles.count)")
        context.coordinator.updateContent(content)
        context.coordinator.updateInfoBubbleLayouts()
        return mapView
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {
        uiView.contentScaleFactor = UIScreen.main.scale
        uiView.layer.contentsScale = UIScreen.main.scale
        if let styleURL = URL(string: state.mapDesignType.styleJsonURL),
           uiView.styleURL != styleURL {
            uiView.styleURL = styleURL
        }
        // ジェスチャはここ（updateUIView）で直接適用する。SwiftUI の同期フックは常に
        // ネイティブビューを持っているのに対し、コントローラはまだ生成されていない／
        // まだ mapView を保持していないことがあり、その場合に設定が落ちる（実機の
        // UISettingsUITests が MapLibre/MapTiler/Mapbox で検出）。
        // コントローラ側の `applyUISettings` は android-sdk と同じ API を提供するための
        // 命令的な入口で、同じ値を同じネイティブプロパティへ書く。
        uiView.isScrollEnabled = state.uiSettings.scrollGesture
        uiView.isZoomEnabled = state.uiSettings.zoomGesture
        uiView.isRotateEnabled = state.uiSettings.rotateGesture
        uiView.isPitchEnabled = state.uiSettings.tiltGesture
        // 制限値が変わったときだけ再適用する（毎フレーム native API を叩かない）。
        context.coordinator.applyCameraRestriction(cameraRestriction)
        MCLog.map("MapLibreMapView.updateUIView updateContent markers=\(content.markers.count) bubbles=\(content.infoBubbles.count)")
        context.coordinator.updateContent(content)
        context.coordinator.updateInfoBubbleLayouts()
    }

    static func dismantleUIView(_ uiView: MLNMapView, coordinator: Coordinator) {
        coordinator.unbind()
        uiView.delegate = nil
    }

    @MainActor
    final class Coordinator: MapViewCoordinatorBase<MapLibreViewState>, MLNMapViewDelegate {
        weak var mapView: MLNMapView?
        // updateUIView から applyUISettings を呼ぶため private を外している。
        private(set) var controller: MapLibreViewController?
        private var markerController: MapLibreMarkerController?
        private var groundImageController: MapLibreGroundImageController?
        private var rasterController: MapLibreRasterLayerController?
        private var circleController: MapLibreCircleController?
        private var polylineController: MapLibrePolylineController?
        private var polygonController: MapLibrePolygonController?
        private var hullPolygonController: MapLibrePolygonController?
        private var overlayScope: MapOverlayScope?
        private var infoBubbleCoordinator: InfoBubbleOverlayCoordinator?
        private lazy var strategyManager = StrategyMarkerManager<MLNPointFeature, MapLibreMarkerRenderer>(
            makeRenderer: { [weak self] strategy in
                guard let mapView = self?.mapView else { fatalError("mapView unavailable") }
                let layer = MarkerLayer(
                    sourceId: "mapconductor-cluster-source-\(UUID().uuidString)",
                    layerId: "mapconductor-cluster-layer-\(UUID().uuidString)"
                )
                return MapLibreMarkerRenderer(mapView: mapView, markerManager: strategy.markerManager, markerLayer: layer)
            },
            shouldAddMarkers: { [weak self] in self?.isStyleLoaded ?? false },
            currentCamera: { [weak self] in
                guard let self, let mapView = self.mapView else { return nil }
                return self.currentCameraPosition(from: mapView)
            }
        )
        private var isStyleLoaded = false
        private weak var loadedStyle: MLNStyle?
        /// android-sdk の `cameraRestriction?.let { controller.setCameraRestriction(it) }` 相当。
        /// 変化検知は `MapViewCoordinatorBase.applyCameraRestriction(_:to:)` が行う。
        func applyCameraRestriction(_ restriction: CameraRestriction?) {
            applyCameraRestriction(restriction, to: controller)
        }

        func bind(state: MapLibreViewState, mapView: MLNMapView) {
            // A strategy can be connected after mapViewDidFinishLoadingMap (the plugin drives
            // this now, during content assembly), so a freshly created renderer has to be given
            // the already-loaded style instead of waiting for a style callback that has passed.
            strategyManager.onRendererCreated = { [weak self] renderer in
                guard let self, self.isStyleLoaded, let style = self.mapView?.style else { return }
                renderer.onStyleLoaded(style)
                self.strategyManager.flush()
            }
            // Publish marker rendering as a map-scoped capability. Add-on modules resolve it
            // from the registry; this provider never learns that clustering exists.
            state.serviceRegistry.put(MarkerRenderingSupportKey.self, strategyManager)

            let controller = MapLibreViewController(mapView: mapView)
            self.controller = controller
            state.setController(controller)
            // 拡張モジュール（ヒートマップ等）がオーバーレイコントローラを登録できるようにする。
            state.serviceRegistry.put(OverlayControllerRegistryKey.self, controller.overlayControllers)
            state.setMapViewHolder(controller.typedHolder)

            let markerController = MapLibreMarkerController(mapView: mapView) { [weak self] id in
                self?.infoBubbleCoordinator?.updateInfoBubblePosition(for: id)
            }
            self.markerController = markerController

            let groundImageController = MapLibreGroundImageController(mapView: mapView)
            self.groundImageController = groundImageController

            let rasterController = MapLibreRasterLayerController(mapView: mapView)
            self.rasterController = rasterController

            let circleController = MapLibreCircleController(mapView: mapView)
            self.circleController = circleController

            let polylineController = MapLibrePolylineController(mapView: mapView)
            self.polylineController = polylineController

            let polygonController = MapLibrePolygonController(mapView: mapView)
            self.polygonController = polygonController
            self.hullPolygonController = MapLibrePolygonController(mapView: mapView)

            let overlayScope = MapOverlayScope()
            self.overlayScope = overlayScope
            bindOverlayCollector(overlayScope.circleCollector, to: circleController)
            bindOverlayCollector(overlayScope.polylineCollector, to: polylineController)
            bindOverlayCollector(overlayScope.polygonCollector, to: polygonController)
            bindOverlayCollector(overlayScope.rasterLayerCollector, to: rasterController)
            // GroundImage is not a core GroundImageController subclass on MapLibre,
            // so it stays on its own sync path (below), not the collector.

            if let loadedStyle {
                applyLoadedStyle(loadedStyle)
            }
            self.infoBubbleCoordinator = InfoBubbleOverlayCoordinator(
                container: infoBubbleContainer,
                project: { [weak self] point in
                    guard let mapView = self?.mapView else { return nil }
                    let coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
                    return mapView.convert(coordinate, toPointTo: mapView)
                },
                resolveMarkerStateForIcon: { [weak markerController] id, bubbleMarker in
                    markerController?.getMarkerState(for: id) ?? bubbleMarker
                },
                iconMetrics: { [weak markerController] markerState in
                    let icon = markerController?.getIcon(for: markerState) ?? (markerState.icon ?? DefaultMarkerIcon()).toBitmapIcon()
                    return MarkerIconMetrics(size: icon.size, anchor: icon.anchor, infoAnchor: icon.infoAnchor)
                }
            )

            // Screen-space marker animation layer: shares the info-bubble
            // container (inserted below the bubbles) and the map projection.
            markerController.renderer.animationOverlay = MarkerAnimationOverlayCoordinator(
                container: infoBubbleContainer,
                project: { [weak self] point in
                    guard let mapView = self?.mapView else { return nil }
                    let coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
                    let p = mapView.convert(coordinate, toPointTo: mapView)
                    return (p.x.isFinite && p.y.isFinite) ? p : nil
                }
            )
        }

        func unbind() {
            // 登録した capability を取り下げる。レジストリの持ち主は state で、ビューより長生きするため、
            // ここで外さないと破棄済みのコントローラを掴んだまま残る。
            state.serviceRegistry.removeProviderRegistrations()
            markerController?.renderer.animationOverlay?.unbind()
            markerController?.renderer.animationOverlay = nil
            // 登録済みオーバーレイコントローラ（拡張モジュール含む）を破棄する。
            controller?.destroy()
            state.setController(nil)
            state.setMapViewHolder(nil)
            controller = nil
            markerController?.unbind()
            markerController = nil
            groundImageController?.unbind()
            groundImageController = nil
            rasterController?.unbind()
            rasterController = nil
            circleController?.unbind()
            circleController = nil
            polylineController?.unbind()
            polylineController = nil
            polygonController?.unbind()
            polygonController = nil
            hullPolygonController?.unbind()
            hullPolygonController = nil
            overlayScope?.clear()
            overlayScope = nil
            infoBubbleCoordinator?.unbind()
            infoBubbleCoordinator = nil
            strategyManager.clear()
            isStyleLoaded = false
            loadedStyle = nil
        }

        func updateContent(_ content: MapViewContent) {
            if let mapView {
                polylineController?.setCurrentCameraPosition(currentCameraPosition(from: mapView))
            }
            infoBubbleCoordinator?.syncInfoBubbles(content.infoBubbles)
            markerController?.tilingOptions = content.markerTilingOptions
            markerController?.syncMarkers(content.markers)
            groundImageController?.syncGroundImages(content.groundImages)
            overlayScope?.rasterLayerCollector.sync(content.rasterLayers.map { $0.state })
            overlayScope?.circleCollector.sync(content.circles.map { $0.state })
            overlayScope?.polylineCollector.sync(content.polylines.map { $0.state })
            overlayScope?.polygonCollector.sync(content.polygons.map { $0.state })
            for handler in content.polygonSyncHandlers {
                let hullController = hullPolygonController
                handler.bindPolygonSync { [weak hullController] states in
                    await hullController?.add(data: states)
                }
            }
            infoBubbleCoordinator?.updateAllLayouts()
        }

        // MARK: - MLNMapViewDelegate

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            isStyleLoaded = true
            loadedStyle = style
            applyLoadedStyle(style)
        }

        private func applyLoadedStyle(_ style: MLNStyle) {
            groundImageController?.onStyleLoaded(style)
            rasterController?.onStyleLoaded(style)
            polygonController?.onStyleLoaded(style)
            hullPolygonController?.onStyleLoaded(style)
            polylineController?.onStyleLoaded(style)
            circleController?.onStyleLoaded(style)
            markerController?.onStyleLoaded(style)
            // Re-emit collector-routed overlays now the style is ready, in case
            // add() ran before load (idempotent). Parity with Mapbox.
            overlayScope?.rasterLayerCollector.flush()
            overlayScope?.circleCollector.flush()
            overlayScope?.polylineCollector.flush()
            overlayScope?.polygonCollector.flush()
            strategyManager.renderer?.onStyleLoaded(style)
            strategyManager.flush()
        }

        func mapViewDidFinishLoadingMap(_ mapView: MLNMapView) {
            performMapLoadedOnce {
                controller?.notifyMapInitialized()
                onMapLoaded?(state)
            }
            updateInfoBubbleLayouts()
        }

        /// ジェスチャーによるカメラ変更を範囲制限で拒否する。
        ///
        /// MapLibre iOS が用意している唯一のカメラ範囲制限フック。境界で滑らかに止まるため、
        /// android-for-maplibre の `setLatLngBoundsForCameraTarget` に最も近い挙動になる。
        /// なおヘッダに明記されているとおり、このデリゲートはプログラム的なカメラ変更
        /// （`centerCoordinate` 設定や `flyToCamera`）では呼ばれない。そちらは
        /// `regionDidChangeAnimated` 側のクランプが担当する。
        func mapView(
            _ mapView: MLNMapView,
            shouldChangeFrom oldCamera: MLNMapCamera,
            to newCamera: MLNMapCamera,
            reason: MLNCameraChangeReason
        ) -> Bool {
            controller?.shouldAllowGestureCameraChange(
                from: oldCamera.centerCoordinate,
                to: newCamera.centerCoordinate
            ) ?? true
        }

        func mapView(_ mapView: MLNMapView, regionWillChangeAnimated animated: Bool) {
            let camera = currentCameraPosition(from: mapView)
            polylineController?.setCurrentCameraPosition(camera)
            controller?.notifyCameraMoveStart(camera)
            onCameraMoveStart?(camera)
            // Removed async Task calls to prevent crashes
            // Geometry layers don't need to respond to camera changes
            Task { [weak self] in
                await self?.strategyManager.onCameraChanged(camera)
            }
            updateInfoBubbleLayouts()
        }

        func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            let camera = currentCameraPosition(from: mapView)
            state.updateCameraPosition(camera)
            polylineController?.setCurrentCameraPosition(camera)
            controller?.notifyCameraMove(camera)
            onCameraMove?(camera)
            // Removed async Task calls to prevent crashes
            // Geometry layers don't need to respond to camera changes
            Task { [weak self] in
                await self?.strategyManager.onCameraChanged(camera)
            }
            updateInfoBubbleLayouts()
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            let camera = currentCameraPosition(from: mapView)
            // パン範囲の制限に違反していれば矩形内へ引き戻す（MapLibre iOS にはネイティブの
            // 範囲制限 API が無いため）。再適用すると regionDidChange が再発火し、
            // そこでは補正不要になり通常フローへ進む。android-sdk の HERE/ArcGIS/TomTom と同じ方式。
            if controller?.applyCameraRestrictionCorrectionIfNeeded(camera) == true { return }
            state.updateCameraPosition(camera)
            polylineController?.setCurrentCameraPosition(camera)
            controller?.notifyCameraMoveEnd(camera)
            onCameraMoveEnd?(camera)
            // Removed async Task calls to prevent crashes
            // Geometry layers don't need to respond to camera changes
            Task { [weak self] in
                await self?.strategyManager.onCameraChanged(camera)
            }
            updateInfoBubbleLayouts()
        }

        @objc func handleMapTap(_ recognizer: UITapGestureRecognizer) {
            guard let mapView = mapView, recognizer.state == .ended else { return }
            let point = recognizer.location(in: mapView)

            // Ensure polyline hit-testing uses the current zoom even if no region-change callbacks have fired yet.
            polylineController?.setCurrentCameraPosition(currentCameraPosition(from: mapView))

            if markerController?.handleTap(at: point) == true {
                updateInfoBubbleLayouts()
                return
            }
            if handleStrategyTap(at: point) {
                updateInfoBubbleLayouts()
                return
            }

            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            if circleController?.handleTap(at: coordinate) == true {
                updateInfoBubbleLayouts()
                return
            }
            if polylineController?.handleTap(at: coordinate) == true {
                updateInfoBubbleLayouts()
                return
            }
            if polygonController?.handleTap(at: coordinate) == true {
                updateInfoBubbleLayouts()
                return
            }
            if groundImageController?.handleTap(at: coordinate) == true {
                updateInfoBubbleLayouts()
                return
            }
            let geoPoint = GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude, altitude: 0)
            controller?.notifyMapClick(geoPoint)
            onMapClick?(geoPoint)
        }

        @objc func handleMarkerLongPress(_ recognizer: UILongPressGestureRecognizer) {
            let handledByMarker = markerController?.handleLongPress(recognizer) ?? false
            if !handledByMarker, recognizer.state == .began, let mapView {
                let point = recognizer.location(in: mapView)
                let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
                let geoPoint = GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude, altitude: 0)
                controller?.notifyMapLongClick(geoPoint)
                onMapLongClick?(geoPoint)
            }
            updateInfoBubbleLayouts()
        }

        // MARK: - Helper Methods

        private func currentCameraPosition(from mapView: MLNMapView) -> MapCameraPosition {
            let visibleBounds = mapView.visibleCoordinateBounds
            let bounds = GeoRectBounds(
                southWest: GeoPoint(
                    latitude: visibleBounds.sw.latitude,
                    longitude: visibleBounds.sw.longitude,
                    altitude: 0
                ),
                northEast: GeoPoint(
                    latitude: visibleBounds.ne.latitude,
                    longitude: visibleBounds.ne.longitude,
                    altitude: 0
                )
            )
            // 4 隅の逆投影は全プロバイダ共通なのでコアの buildVisibleRegion を使う。
            // bounds だけはネイティブの visibleCoordinateBounds の方が正確なので差し替える。
            let corners = MapLibreMapViewHolder(mapView: mapView).buildVisibleRegion()
            let visibleRegion = VisibleRegion(
                bounds: bounds,
                nearLeft: corners?.nearLeft,
                nearRight: corners?.nearRight,
                farLeft: corners?.farLeft,
                farRight: corners?.farRight
            )
            return mapView.toMapCameraPosition(
                logicalTiltHint: controller?.lastLogicalTilt,
                visibleRegion: visibleRegion
            )
        }

        fileprivate func updateInfoBubbleLayouts() {
            infoBubbleCoordinator?.updateAllLayouts()
        }

        private func handleStrategyTap(at point: CGPoint) -> Bool {
            guard let markerId = strategyManager.renderer?.markerId(at: point),
                  let state = strategyManager.controller?.markerManager.getEntity(markerId)?.state,
                  state.clickable else { return false }
            strategyManager.controller?.dispatchClick(state)
            return true
        }

        private func geoPoint(at point: CGPoint, mapView: MLNMapView) -> GeoPoint? {
            guard !mapView.bounds.isEmpty else { return nil }
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            return GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude, altitude: 0)
        }
    }
}
