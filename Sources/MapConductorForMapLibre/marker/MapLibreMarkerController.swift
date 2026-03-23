import Combine
import CoreGraphics
import CoreLocation
import MapLibre
import MapConductorCore

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
        setupTileRenderer()
    }

    private func setupTileRenderer() {
        let routeId = "mapconductor-markers-\(UUID().uuidString)"
        let renderer = MarkerTileRenderer<MLNPointFeature>(
            markerManager: markerManager,
            tileSize: 256,
            cacheSizeBytes: tilingOptions.cacheSize,
            debugTileOverlay: tilingOptions.debugTileOverlay,
            iconScaleCallback: tilingOptions.iconScaleCallback
        )
        TileServerRegistry.get().register(routeId: routeId, provider: renderer)
        tileRenderer = renderer
        tileRouteId = routeId
    }

    func onStyleLoaded(_ style: MLNStyle) {
        isStyleLoaded = true
        MCLog.marker("MapLibreMarkerController.onStyleLoaded")
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
            await super.add(data: data)
            return
        }

        let shouldTileAll = data.count >= tilingOptions.minMarkerCount
        let result = await MarkerIngestionEngine.ingest(
            data: data,
            markerManager: markerManager,
            renderer: renderer,
            defaultMarkerIcon: defaultMarkerIconForTiling,
            tilingEnabled: tilingOptions.enabled,
            tiledMarkerIds: &tiledMarkerIds,
            shouldTile: { [shouldTileAll] _ in shouldTileAll }
        )

        if result.tiledDataChanged, let tileRenderer {
            tileRenderer.invalidate()
            tileVersion += 1
            if let style = mapView?.style {
                updateTileLayer(style: style, hasTiledMarkers: result.hasTiledMarkers)
            }
        }
    }

    private func updateTileLayer(style: MLNStyle, hasTiledMarkers: Bool) {
        guard let routeId = tileRouteId else { return }
        let server = TileServerRegistry.get()
        let urlTemplate = server.urlTemplate(routeId: routeId, version: tileVersion)
        let sourceId = tileSourceId ?? "mapconductor-tile-markers-source-\(routeId)"
        let layerId = tileLayerId ?? "mapconductor-tile-markers-layer-\(routeId)"
        tileSourceId = sourceId
        tileLayerId = layerId

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
