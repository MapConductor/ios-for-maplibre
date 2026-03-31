import Combine
import CoreGraphics
import CoreLocation
import MapLibre
import MapConductorCore
import UIKit

@MainActor
final class MapLibreMarkerController: AbstractMarkerController<MLNPointFeature, MapLibreMarkerRenderer> {
    private weak var mapView: MLNMapView?

    private var markerSubscriptions: [String: AnyCancellable] = [:]
    private var markerStatesById: [String: MarkerState] = [:]
    private var latestStates: [MarkerState] = []
    private var isStyleLoaded: Bool = false

    private var eventController: MapLibreMarkerEventController?
    let onUpdateInfoBubble: (String) -> Void

    // MARK: - Marker tiling

    var tilingOptions: MarkerTilingOptions = .Default
    private var tileRenderer: MarkerTileRenderer<MLNPointFeature>?
    private var tileRouteId: String?
    private var tileVersion: Int64 = 0
    private var tiledMarkerIds: Set<String> = []
    private var tileSourceId: String?
    private var tileLayerId: String?
    private var lastServerBaseUrl: String = ""
    private let defaultMarkerIconForTiling: BitmapIcon = DefaultMarkerIcon().toBitmapIcon()

    init(mapView: MLNMapView?, onUpdateInfoBubble: @escaping (String) -> Void) {
        self.mapView = mapView
        self.onUpdateInfoBubble = onUpdateInfoBubble

        let markerManager = MarkerManager<MLNPointFeature>.defaultManager()
        let layer = MarkerLayer(
            sourceId: "mapconductor-markers-source-\(UUID().uuidString)",
            layerId: "mapconductor-markers-layer-\(UUID().uuidString)"
        )

        let renderer = MapLibreMarkerRenderer(
            mapView: mapView,
            markerManager: markerManager,
            markerLayer: layer
        )

        super.init(markerManager: markerManager, renderer: renderer)

        self.eventController = MapLibreMarkerEventController(mapView: mapView, markerController: self)
    }

    private static var retinaAwareTileSize: Int {
        256 * max(1, Int(UIScreen.main.scale))
    }

    private func setupTileRenderer() {
        let routeId = "mapconductor-markers-\(UUID().uuidString)"
        let contentScale = Double(UIScreen.main.scale)
        let baseCallback = tilingOptions.iconScaleCallback
        let scaledCallback: ((MarkerState, Int) -> Double)? = { state, zoom in
            (baseCallback?(state, zoom) ?? 1.0) * contentScale
        }
        let renderer = MarkerTileRenderer<MLNPointFeature>(
            markerManager: markerManager,
            tileSize: Self.retinaAwareTileSize,
            cacheSizeBytes: tilingOptions.cacheSize,
            debugTileOverlay: tilingOptions.debugTileOverlay,
            iconScaleCallback: scaledCallback
        )
        TileServerRegistry.get().register(routeId: routeId, provider: renderer)
        tileRenderer = renderer
        tileRouteId = routeId
    }

    func onStyleLoaded(_ style: MLNStyle) {
        isStyleLoaded = true
        MCLog.marker("MapLibreMarkerController.onStyleLoaded tiledCount=\(tiledMarkerIds.count) latestStates=\(latestStates.count)")
        renderer.onStyleLoaded(style)
        // Re-attach tile raster layer if there are already tiled markers
        if !tiledMarkerIds.isEmpty {
            updateTileLayer(style: style, hasTiledMarkers: true)
        }
        if !latestStates.isEmpty {
            Task { [weak self] in
                guard let self else { return }
                await self.add(data: self.latestStates)
            }
        }
    }

    func handleTap(at point: CGPoint) -> Bool {
        eventController?.handleTap(at: point) ?? false
    }

    func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        eventController?.handleLongPress(recognizer)
    }

    func syncMarkers(_ markers: [Marker]) {
        MCLog.marker("MapLibreMarkerController.syncMarkers count=\(markers.count) styleLoaded=\(isStyleLoaded)")
        let newIds = Set(markers.map { $0.id })
        let oldIds = Set(markerStatesById.keys)

        var newStatesById: [String: MarkerState] = [:]
        var shouldSyncList = false
        for marker in markers {
            let state = marker.state
            if let existingState = markerStatesById[state.id], existingState !== state {
                markerSubscriptions[state.id]?.cancel()
                markerSubscriptions.removeValue(forKey: state.id)
                // State instance changed: ensure controller updates entity reference.
                shouldSyncList = true
            }
            newStatesById[state.id] = state
            if !markerManager.hasEntity(state.id) {
                shouldSyncList = true
            }
        }

        markerStatesById = newStatesById
        latestStates = markers.map { $0.state }

        if oldIds != newIds {
            shouldSyncList = true
        }

        if isStyleLoaded, shouldSyncList {
            Task { [weak self] in
                guard let self else { return }
                MCLog.marker("MapLibreMarkerController.syncMarkers -> add()")
                await self.add(data: self.latestStates)
            }
        } else if isStyleLoaded {
            refreshTileLayerIfNeeded()
        }

        for marker in markers {
            subscribeToMarker(marker.state)
            onUpdateInfoBubble(marker.id)
        }

        let removedIds = oldIds.subtracting(newIds)
        for id in removedIds {
            markerSubscriptions[id]?.cancel()
            markerSubscriptions.removeValue(forKey: id)
        }
    }

    private func subscribeToMarker(_ state: MarkerState) {
        guard markerSubscriptions[state.id] == nil else { return }
        MCLog.marker("MapLibreMarkerController.subscribe id=\(state.id)")
        markerSubscriptions[state.id] = state.asFlow()
            .dropFirst() // Skip initial value to avoid triggering update on subscription
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard self.markerStatesById[state.id] != nil else { return }
                MCLog.marker("MapLibreMarkerController.asFlow emit id=\(state.id) anim=\(String(describing: state.getAnimation()))")
                Task { [weak self] in
                    guard let self else { return }
                    await self.update(state: state)
                    self.onUpdateInfoBubble(state.id)
                }
            }
    }

    func getMarkerState(for id: String) -> MarkerState? {
        markerManager.getEntity(id)?.state
    }

    func getIcon(for state: MarkerState) -> BitmapIcon {
        let resolvedIcon = state.icon ?? DefaultMarkerIcon()
        return resolvedIcon.toBitmapIcon()
    }

    // MARK: - Tiled marker override

    override func add(data: [MarkerState]) async {
        guard tilingOptions.enabled else {
            MCLog.marker("MapLibreMarkerController.add tilingDisabled count=\(data.count)")
            await super.add(data: data)
            return
        }
        if tileRenderer == nil { setupTileRenderer() }

        let shouldTileAll = data.count >= tilingOptions.minMarkerCount
        MCLog.marker("MapLibreMarkerController.add count=\(data.count) minMarkerCount=\(tilingOptions.minMarkerCount) shouldTileAll=\(shouldTileAll)")
        var localTiledMarkerIds = tiledMarkerIds
        let result = await MarkerIngestionEngine.ingest(
            data: data,
            markerManager: markerManager,
            renderer: renderer,
            defaultMarkerIcon: defaultMarkerIconForTiling,
            tilingEnabled: tilingOptions.enabled,
            tiledMarkerIds: &localTiledMarkerIds,
            shouldTile: { [shouldTileAll] _ in shouldTileAll }
        )
        tiledMarkerIds = localTiledMarkerIds
        MCLog.marker("MapLibreMarkerController.add ingest done tiledDataChanged=\(result.tiledDataChanged) hasTiledMarkers=\(result.hasTiledMarkers) tiledCount=\(tiledMarkerIds.count) style=\(mapView?.style != nil)")

        if result.tiledDataChanged, let tileRenderer {
            tileRenderer.invalidate()
            tileVersion += 1
            if let style = mapView?.style {
                updateTileLayer(style: style, hasTiledMarkers: result.hasTiledMarkers)
            } else {
                MCLog.marker("MapLibreMarkerController.add skipped updateTileLayer: style not loaded")
            }
        }
    }

    private func refreshTileLayerIfNeeded() {
        guard !tiledMarkerIds.isEmpty, let style = mapView?.style else { return }
        let server = TileServerRegistry.get()
        guard server.baseUrl != lastServerBaseUrl else { return }
        MCLog.marker("MapLibreMarkerController.refreshTileLayerIfNeeded serverRestarted oldUrl=\(lastServerBaseUrl) newUrl=\(server.baseUrl)")
        updateTileLayer(style: style, hasTiledMarkers: true)
    }

    private func updateTileLayer(style: MLNStyle, hasTiledMarkers: Bool) {
        guard let routeId = tileRouteId else { return }
        let server = TileServerRegistry.get()
        lastServerBaseUrl = server.baseUrl
        let urlTemplate = server.urlTemplate(routeId: routeId, version: tileVersion)
        let sourceId = tileSourceId ?? "mapconductor-tile-markers-source-\(routeId)"
        let layerId = tileLayerId ?? "mapconductor-tile-markers-layer-\(routeId)"
        tileSourceId = sourceId
        tileLayerId = layerId
        MCLog.marker("MapLibreMarkerController.updateTileLayer hasTiledMarkers=\(hasTiledMarkers) version=\(tileVersion) urlTemplate=\(urlTemplate)")

        // Remove old layer/source
        if let existingLayer = style.layer(withIdentifier: layerId) {
            style.removeLayer(existingLayer)
        }
        if let existingSource = style.source(withIdentifier: sourceId) {
            style.removeSource(existingSource)
        }

        guard hasTiledMarkers else { return }

        let options: [MLNTileSourceOption: Any] = [.tileSize: NSNumber(value: 256)]
        let source = MLNRasterTileSource(identifier: sourceId, tileURLTemplates: [urlTemplate], options: options)
        let layer = MLNRasterStyleLayer(identifier: layerId, source: source)
        style.addSource(source)
        style.addLayer(layer)
    }

    /// Hit-test tiled markers at the given screen point (pts). Returns true if a clickable marker was found.
    func handleTiledMarkerTap(at screenPoint: CGPoint) -> Bool {
        MCLog.marker("MapLibreMarkerController.handleTiledMarkerTap point=\(screenPoint) tiledCount=\(tiledMarkerIds.count)")
        guard !tiledMarkerIds.isEmpty, let mapView else { return false }
        let clickRadiusPt: CGFloat = 44
        var bestState: MarkerState? = nil
        var bestDist = CGFloat.infinity

        for id in tiledMarkerIds {
            guard let entity = markerManager.getEntity(id), entity.state.clickable else { continue }
            let coord = CLLocationCoordinate2D(
                latitude: entity.state.position.latitude,
                longitude: entity.state.position.longitude
            )
            let markerPoint = mapView.convert(coord, toPointTo: mapView)
            let dist = hypot(screenPoint.x - markerPoint.x, screenPoint.y - markerPoint.y)
            if dist < clickRadiusPt && dist < bestDist {
                bestDist = dist
                bestState = entity.state
            }
        }

        if let state = bestState {
            MCLog.marker("MapLibreMarkerController.handleTiledMarkerTap hit id=\(state.id) dist=\(bestDist)")
            dispatchClick(state: state)
            return true
        }
        MCLog.marker("MapLibreMarkerController.handleTiledMarkerTap miss")
        return false
    }

    func unbind() {
        markerSubscriptions.values.forEach { $0.cancel() }
        markerSubscriptions.removeAll()
        markerStatesById.removeAll()
        latestStates.removeAll()
        isStyleLoaded = false
        if let routeId = tileRouteId {
            TileServerRegistry.get().unregister(routeId: routeId)
        }
        tileRenderer = nil
        tileRouteId = nil
        tiledMarkerIds.removeAll()
        eventController?.unbind()
        eventController = nil
        renderer.unbind()
        mapView = nil
        destroy()
    }
}
