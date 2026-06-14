import MapConductorCore
import MapLibre
import UIKit

@MainActor
final class MapLibrePolygonOverlayRenderer: AbstractPolygonOverlayRenderer<[MLNPolygonFeature]> {
    private weak var mapView: MLNMapView?
    private var style: MLNStyle?

    let polygonLayer: PolygonLayer
    private let polygonManager: PolygonManager<[MLNPolygonFeature]>
    private var masks: [String: MapLibreMaskHandle] = [:]

    init(
        mapView: MLNMapView?,
        polygonManager: PolygonManager<[MLNPolygonFeature]>,
        polygonLayer: PolygonLayer
    ) {
        self.mapView = mapView
        self.polygonManager = polygonManager
        self.polygonLayer = polygonLayer
        super.init()
    }

    func onStyleLoaded(_ style: MLNStyle) {
        self.style = style
        polygonLayer.ensureAdded(to: style)
        // Re-register raster sources/layers for any existing masks after style reload
        for (_, handle) in masks {
            addMaskLayerToStyle(style, handle: handle)
        }
    }

    func unbind() {
        masks.values.forEach { handle in
            TileServerRegistry.get().unregister(routeId: handle.routeId)
        }
        masks.removeAll()
        if let style {
            polygonLayer.remove(from: style)
        }
        style = nil
        mapView = nil
    }

    override func createPolygon(state: PolygonState) async -> [MLNPolygonFeature]? {
        if state.holes.isEmpty {
            removeMask(id: state.id)
            return createMapLibrePolygons(
                id: state.id,
                points: state.points,
                geodesic: state.geodesic,
                fillColor: state.fillColor,
                strokeColor: state.strokeColor,
                strokeWidth: state.strokeWidth,
                zIndex: state.zIndex,
                holes: state.holes
            )
        } else {
            ensureMask(state: state)
            return createMapLibrePolygons(
                id: state.id,
                points: state.points,
                geodesic: state.geodesic,
                fillColor: .clear,
                strokeColor: state.strokeColor,
                strokeWidth: state.strokeWidth,
                zIndex: state.zIndex,
                holes: []
            )
        }
    }

    override func updatePolygonProperties(
        polygon: [MLNPolygonFeature],
        current: PolygonEntity<[MLNPolygonFeature]>,
        prev: PolygonEntity<[MLNPolygonFeature]>
    ) async -> [MLNPolygonFeature]? {
        return await createPolygon(state: current.state)
    }

    override func removePolygon(entity: PolygonEntity<[MLNPolygonFeature]>) async {
        removeMask(id: entity.state.id)
    }

    override func onPostProcess() async {
        let features = polygonManager.allEntities().flatMap { $0.polygon ?? [] }
        polygonLayer.setFeatures(features)
    }

    // MARK: - Mask (raster tile overlay for hole polygons)

    private func ensureMask(state: PolygonState) {
        let id = state.id
        if let existing = masks[id] {
            existing.tileRenderer.update(
                points: state.points,
                holes: state.holes,
                fillColor: state.fillColor,
                geodesic: state.geodesic
            )
            return
        }

        let tileRenderer = PolygonRasterTileRenderer(tileSize: 256)
        tileRenderer.update(
            points: state.points,
            holes: state.holes,
            fillColor: state.fillColor,
            geodesic: state.geodesic
        )

        let routeId = "polygon-raster-\(safeId(id))"
        let cacheKey = String(abs(routeId.hashValue))
        let tileServer = TileServerRegistry.get(forceNoStoreCache: true)
        tileServer.register(routeId: routeId, provider: tileRenderer)
        let urlTemplate = tileServer.urlTemplate(routeId: routeId, tileSize: 256, cacheKey: cacheKey)
        let sourceId = "mapconductor-polygon-mask-source-\(safeId(id))"
        let layerId = "mapconductor-polygon-mask-layer-\(safeId(id))"

        let handle = MapLibreMaskHandle(
            routeId: routeId,
            tileRenderer: tileRenderer,
            sourceId: sourceId,
            layerId: layerId,
            urlTemplate: urlTemplate
        )
        masks[id] = handle

        if let style {
            addMaskLayerToStyle(style, handle: handle)
        }
    }

    private func addMaskLayerToStyle(_ style: MLNStyle, handle: MapLibreMaskHandle) {
        // Remove stale source/layer if present
        if let old = style.layer(withIdentifier: handle.layerId) {
            style.removeLayer(old)
        }
        if let old = style.source(withIdentifier: handle.sourceId) {
            style.removeSource(old)
        }

        let source = MLNRasterTileSource(
            identifier: handle.sourceId,
            tileURLTemplates: [handle.urlTemplate],
            options: [.tileSize: 256, .maximumZoomLevel: NSNumber(value: 22)]
        )
        style.addSource(source)

        let layer = MLNRasterStyleLayer(identifier: handle.layerId, source: source)
        // Insert above the polygon fill layer so the raster fill is visible, but below stroke
        if let lineLayer = polygonLayer.lineLayer {
            style.insertLayer(layer, below: lineLayer)
        } else {
            style.addLayer(layer)
        }
    }

    private func removeMask(id: String) {
        guard let handle = masks.removeValue(forKey: id) else { return }
        TileServerRegistry.get().unregister(routeId: handle.routeId)
        if let style {
            if let layer = style.layer(withIdentifier: handle.layerId) {
                style.removeLayer(layer)
            }
            if let source = style.source(withIdentifier: handle.sourceId) {
                style.removeSource(source)
            }
        }
    }

    private func safeId(_ id: String) -> String {
        id.map { ch in
            ch.isLetter || ch.isNumber || ch == "-" || ch == "_" ? String(ch) : "_"
        }.joined()
    }
}

private struct MapLibreMaskHandle {
    let routeId: String
    let tileRenderer: PolygonRasterTileRenderer
    let sourceId: String
    let layerId: String
    let urlTemplate: String
}
