import Combine
import Foundation
import MapConductorCore
import MapLibre
import SwiftUI
import UIKit

public struct MapLibreMapView: View {
    @ObservedObject private var state: MapLibreViewState

    private let onMapLoaded: OnMapLoadedHandler<MapLibreViewState>?
    private let onMapClick: OnMapEventHandler?
    private let onMapLongClick: OnMapEventHandler?
    private let onCameraMoveStart: OnCameraMoveHandler?
    private let onCameraMove: OnCameraMoveHandler?
    private let onCameraMoveEnd: OnCameraMoveHandler?
    private let content: () -> MapViewContent

    public init(
        state: MapLibreViewState,
        onMapLoaded: OnMapLoadedHandler<MapLibreViewState>? = nil,
        onMapClick: OnMapEventHandler? = nil,
        onMapLongClick: OnMapEventHandler? = nil,
        onCameraMoveStart: OnCameraMoveHandler? = nil,
        onCameraMove: OnCameraMoveHandler? = nil,
        onCameraMoveEnd: OnCameraMoveHandler? = nil,
        @MapViewContentBuilder content: @escaping () -> MapViewContent = { MapViewContent() }
    ) {
        self.state = state
        self.onMapLoaded = onMapLoaded
        self.onMapClick = onMapClick
        self.onMapLongClick = onMapLongClick
        self.onCameraMoveStart = onCameraMoveStart
        self.onCameraMove = onCameraMove
        self.onCameraMoveEnd = onCameraMoveEnd
        self.content = content
    }

    public var body: some View {
        let mapContent = content()
        return ZStack {
            MapLibreMapViewRepresentable(
                state: state,
                onMapLoaded: onMapLoaded,
                onMapClick: onMapClick,
                onMapLongClick: onMapLongClick,
                onCameraMoveStart: onCameraMoveStart,
                onCameraMove: onCameraMove,
                onCameraMoveEnd: onCameraMoveEnd,
                content: mapContent
            )
            ForEach(0..<mapContent.views.count, id: \.self) { index in
                mapContent.views[index]
            }
        }
    }
}

private struct MapLibreMapViewRepresentable: UIViewRepresentable {
    @ObservedObject var state: MapLibreViewState

    let onMapLoaded: OnMapLoadedHandler<MapLibreViewState>?
    let onMapClick: OnMapEventHandler?
    let onMapLongClick: OnMapEventHandler?
    let onCameraMoveStart: OnCameraMoveHandler?
    let onCameraMove: OnCameraMoveHandler?
    let onCameraMoveEnd: OnCameraMoveHandler?
    let content: MapViewContent

    func makeCoordinator() -> Coordinator {
        Coordinator(
            state: state,
            onMapLoaded: onMapLoaded,
            onMapClick: onMapClick,
            onMapLongClick: onMapLongClick,
            onCameraMoveStart: onCameraMoveStart,
            onCameraMove: onCameraMove,
            onCameraMoveEnd: onCameraMoveEnd
        )
    }

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero)
        // Prefer full-resolution rendering on Retina displays.
        // (MapLibre uses the view's pixel ratio for both tiles and symbols.)
        mapView.contentScaleFactor = UIScreen.main.scale
        mapView.layer.contentsScale = UIScreen.main.scale
        if let styleURL = URL(string: state.mapDesignType.styleJsonURL) {
            mapView.styleURL = styleURL
        }
        mapView.prefetchesTiles = false
        mapView.tileCacheEnabled = false
        mapView.isScrollEnabled = state.uiSettings.scrollGesture
        mapView.delegate = context.coordinator
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
        uiView.isScrollEnabled = state.uiSettings.scrollGesture
        MCLog.map("MapLibreMapView.updateUIView updateContent markers=\(content.markers.count) bubbles=\(content.infoBubbles.count)")
        context.coordinator.updateContent(content)
        context.coordinator.updateInfoBubbleLayouts()
    }

    static func dismantleUIView(_ uiView: MLNMapView, coordinator: Coordinator) {
        coordinator.unbind()
        uiView.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, MLNMapViewDelegate {
        private let state: MapLibreViewState
        private let onMapLoaded: OnMapLoadedHandler<MapLibreViewState>?
        private let onMapClick: OnMapEventHandler?
        private let onMapLongClick: OnMapEventHandler?
        private let onCameraMoveStart: OnCameraMoveHandler?
        private let onCameraMove: OnCameraMoveHandler?
        private let onCameraMoveEnd: OnCameraMoveHandler?

        weak var mapView: MLNMapView?
        private var controller: MapLibreViewController?
        private var markerController: MapLibreMarkerController?
        private var groundImageController: MapLibreGroundImageController?
        private var rasterController: MapLibreRasterLayerController?
        private var circleController: MapLibreCircleController?
        private var polylineController: MapLibrePolylineController?
        private var polygonController: MapLibrePolygonController?
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
            shouldAddMarkers: { [weak self] in self?.isStyleLoaded ?? false }
        )
        private var isStyleLoaded = false

        private var didCallMapLoaded = false
        private let infoBubbleContainer = PassthroughContainerView()

        init(
            state: MapLibreViewState,
            onMapLoaded: OnMapLoadedHandler<MapLibreViewState>?,
            onMapClick: OnMapEventHandler?,
            onMapLongClick: OnMapEventHandler?,
            onCameraMoveStart: OnCameraMoveHandler?,
            onCameraMove: OnCameraMoveHandler?,
            onCameraMoveEnd: OnCameraMoveHandler?
        ) {
            self.state = state
            self.onMapLoaded = onMapLoaded
            self.onMapClick = onMapClick
            self.onMapLongClick = onMapLongClick
            self.onCameraMoveStart = onCameraMoveStart
            self.onCameraMove = onCameraMove
            self.onCameraMoveEnd = onCameraMoveEnd
        }

        func bind(state: MapLibreViewState, mapView: MLNMapView) {
            let controller = MapLibreViewController(mapView: mapView)
            self.controller = controller
            state.setController(controller)
            state.setMapViewHolder(controller.holder)

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
            if let style = mapView.style {
                groundImageController.onStyleLoaded(style)
                rasterController.onStyleLoaded(style)
                polygonController.onStyleLoaded(style)
                polylineController.onStyleLoaded(style)
                circleController.onStyleLoaded(style)
                markerController.onStyleLoaded(style)
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
            markerController?.renderer.animationOverlay?.unbind()
            markerController?.renderer.animationOverlay = nil
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
            infoBubbleCoordinator?.unbind()
            infoBubbleCoordinator = nil
            strategyManager.clear()
            isStyleLoaded = false
        }

        func updateContent(_ content: MapViewContent) {
            if let mapView {
                polylineController?.setCurrentCameraPosition(currentCameraPosition(from: mapView))
            }
            infoBubbleCoordinator?.syncInfoBubbles(content.infoBubbles)
            markerController?.tilingOptions = content.markerTilingOptions
            markerController?.syncMarkers(content.markers)
            if let mapView {
                strategyManager.update(content: content, initialCamera: currentCameraPosition(from: mapView))
            }
            groundImageController?.syncGroundImages(content.groundImages)
            rasterController?.syncRasterLayers(content.rasterLayers)
            circleController?.syncCircles(content.circles)
            polylineController?.syncPolylines(content.polylines)
            polygonController?.syncPolygons(content.polygons)
            infoBubbleCoordinator?.updateAllLayouts()
        }

        // MARK: - MLNMapViewDelegate

        func mapViewDidFinishLoadingMap(_ mapView: MLNMapView) {
            isStyleLoaded = true
            if let style = mapView.style {
                groundImageController?.onStyleLoaded(style)
                rasterController?.onStyleLoaded(style)
                polygonController?.onStyleLoaded(style)
                polylineController?.onStyleLoaded(style)
                circleController?.onStyleLoaded(style)
                markerController?.onStyleLoaded(style)
                strategyManager.renderer?.onStyleLoaded(style)
                strategyManager.flush()
            }
            if !didCallMapLoaded {
                didCallMapLoaded = true
                controller?.notifyMapInitialized()
                onMapLoaded?(state)
            }
            updateInfoBubbleLayouts()
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
            let visibleRegion = VisibleRegion(
                bounds: bounds,
                nearLeft: geoPoint(at: CGPoint(x: 0, y: mapView.bounds.maxY), mapView: mapView),
                nearRight: geoPoint(at: CGPoint(x: mapView.bounds.maxX, y: mapView.bounds.maxY), mapView: mapView),
                farLeft: geoPoint(at: CGPoint(x: 0, y: 0), mapView: mapView),
                farRight: geoPoint(at: CGPoint(x: mapView.bounds.maxX, y: 0), mapView: mapView)
            )
            return mapView.toMapCameraPosition(
                logicalTiltHint: controller?.lastLogicalTilt,
                visibleRegion: visibleRegion
            )
        }

        fileprivate func attachInfoBubbleContainer(to mapView: MLNMapView) {
            guard infoBubbleContainer.superview !== mapView else { return }
            infoBubbleContainer.backgroundColor = .clear
            infoBubbleContainer.isUserInteractionEnabled = true  // Enable interaction for InfoBubble buttons
            infoBubbleContainer.frame = mapView.bounds
            infoBubbleContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            mapView.addSubview(infoBubbleContainer)
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
