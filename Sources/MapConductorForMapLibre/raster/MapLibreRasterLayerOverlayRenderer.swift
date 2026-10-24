import MapConductorCore
import MapLibre

final class MapLibreRasterLayer {
    let source: MLNRasterTileSource
    let layer: MLNRasterStyleLayer

    init(source: MLNRasterTileSource, layer: MLNRasterStyleLayer) {
        self.source = source
        self.layer = layer
    }
}

@MainActor
final class MapLibreRasterLayerOverlayRenderer: AbstractRasterLayerOverlayRenderer<MapLibreRasterLayer> {
    private weak var mapView: MLNMapView?
    private var loadedStyle: MLNStyle?

    /// The style, only while it is the one the map draws.
    ///
    /// `MLNMapView.style` is nil while a new style loads and a different
    /// object once it has. The object handed to `onStyleLoaded` outlives the
    /// native style it wrapped, and touching it after a handoff reads freed
    /// memory: a raster layer added while a vector style was replacing the
    /// basemap took MapTiler down with a SIGSEGV in `createLayerSync`. A
    /// layer skipped here is made again by `onStyleLoaded` for the new style.
    private var style: MLNStyle? {
        guard let loadedStyle, let current = mapView?.style, current === loadedStyle else { return nil }
        return loadedStyle
    }

    init(mapView: MLNMapView?) {
        self.mapView = mapView
        super.init()
    }

    func onStyleLoaded(_ style: MLNStyle) {
        loadedStyle = style
    }

    func unbind() {
        loadedStyle = nil
        mapView = nil
    }

    // Synchronous versions of layer operations to avoid async/await issues
    func createLayerSync(state: RasterLayerState) -> MapLibreRasterLayer? {
        guard let style else { return nil }

        let sourceId = "mapconductor-raster-source-\(state.id)"
        let layerId = "mapconductor-raster-layer-\(state.id)"

        // Remove existing layer and source if they already exist
        if let existingLayer = style.layer(withIdentifier: layerId) {
            style.removeLayer(existingLayer)
        }
        if let existingSource = style.source(withIdentifier: sourceId) {
            style.removeSource(existingSource)
        }

        let source = makeTileSource(id: sourceId, source: state.source)
        let layer = MLNRasterStyleLayer(identifier: layerId, source: source)
        layer.rasterOpacity = NSExpression(forConstantValue: state.opacity)
        layer.isVisible = state.visible

        style.addSource(source)
        if state.debug {
            NSLog("[MapConductor] RasterLayer debug mode: id=%@", state.id)
        }
        insertLayer(layer, zIndex: state.zIndex, style: style)

        return MapLibreRasterLayer(source: source, layer: layer)
    }

    /// zIndex orders MapConductor raster layers among themselves; the basemap
    /// style's own layers always stay below. Mapping zIndex to a raw style
    /// index put zIndex=0 layers at the bottom of the style stack — beneath
    /// the basemap — so they rendered but were never visible.
    private func insertLayer(_ layer: MLNRasterStyleLayer, zIndex: Int, style: MLNStyle) {
        let conductorIndices = style.layers.indices.filter {
            style.layers[$0].identifier.hasPrefix("mapconductor-raster-layer-")
        }
        if zIndex >= 0, zIndex < conductorIndices.count {
            style.insertLayer(layer, at: UInt(conductorIndices[zIndex]))
            return
        }
        if let anchor = firstBasemapLabelLayer(style) {
            style.insertLayer(layer, below: anchor)
        } else {
            style.addLayer(layer)
        }
    }

    /// A raster overlay goes above the basemap's geometry but **below its
    /// labels**.
    ///
    /// Appended at the top of the style instead, it covers the place names,
    /// road names and shields the backend draws -- a vector tile layer's own
    /// roads run straight through them, which is what "the labels are under
    /// the lines" looks like. Every raster overlay we add has the same
    /// problem, so the rule lives here rather than in each of them.
    ///
    /// Our own layers are skipped when looking for the anchor: markers are a
    /// symbol layer too, and anchoring to them would put the raster back above
    /// the labels -- and only once a marker existed.
    private func firstBasemapLabelLayer(_ style: MLNStyle) -> MLNStyleLayer? {
        style.layers.first {
            $0 is MLNSymbolStyleLayer && !$0.identifier.hasPrefix("mapconductor-")
        }
    }

    func updateLayerSync(
        layer: MapLibreRasterLayer,
        current: RasterLayerEntity<MapLibreRasterLayer>,
        prev: RasterLayerEntity<MapLibreRasterLayer>
    ) -> MapLibreRasterLayer? {
        let finger = current.fingerPrint
        let prevFinger = prev.fingerPrint

        guard let style else { return layer }

        if finger.source != prevFinger.source {
            // Recreate layer with new source
            if style.layer(withIdentifier: layer.layer.identifier) != nil {
                style.removeLayer(layer.layer)
            }
            if style.source(withIdentifier: layer.source.identifier) != nil {
                style.removeSource(layer.source)
            }
            return createLayerSync(state: current.state)
        }

        if finger.debug != prevFinger.debug && current.state.debug {
            NSLog("[MapConductor] RasterLayer debug mode: id=%@", current.state.id)
        }

        if finger.zIndex != prevFinger.zIndex {
            style.removeLayer(layer.layer)
            insertLayer(layer.layer, zIndex: current.state.zIndex, style: style)
        }

        if finger.opacity != prevFinger.opacity {
            layer.layer.rasterOpacity = NSExpression(forConstantValue: current.state.opacity)
        }

        if finger.visible != prevFinger.visible {
            layer.layer.isVisible = current.state.visible
        }

        return layer
    }

    func removeLayerSync(entity: RasterLayerEntity<MapLibreRasterLayer>) {
        guard let style, let layer = entity.layer else { return }

        if style.layer(withIdentifier: layer.layer.identifier) != nil {
            style.removeLayer(layer.layer)
        }
        if style.source(withIdentifier: layer.source.identifier) != nil {
            style.removeSource(layer.source)
        }
    }

    override func createLayer(state: RasterLayerState) async -> MapLibreRasterLayer? {
        // Delegate to synchronous version to avoid async/await issues
        return createLayerSync(state: state)
    }

    override func updateLayerProperties(
        layer: MapLibreRasterLayer,
        current: RasterLayerEntity<MapLibreRasterLayer>,
        prev: RasterLayerEntity<MapLibreRasterLayer>
    ) async -> MapLibreRasterLayer? {
        // Delegate to synchronous version to avoid async/await issues
        return updateLayerSync(layer: layer, current: current, prev: prev)
    }

    override func removeLayer(entity: RasterLayerEntity<MapLibreRasterLayer>) async {
        // Delegate to synchronous version to avoid async/await issues
        removeLayerSync(entity: entity)
    }

    private func makeTileSource(id: String, source: RasterLayerSource) -> MLNRasterTileSource {
        switch source {
        case let .urlTemplate(template, tileSize, minZoom, maxZoom, _, scheme):
            var options: [MLNTileSourceOption: Any] = [
                .tileSize: NSNumber(value: tileSize)
            ]
            if let minZoom {
                options[.minimumZoomLevel] = NSNumber(value: minZoom)
            }
            if let maxZoom {
                options[.maximumZoomLevel] = NSNumber(value: maxZoom)
            }
            options[.tileCoordinateSystem] =
                NSNumber(
                    value:
                        scheme == .TMS
                            ? MLNTileCoordinateSystem.TMS.rawValue
                            : MLNTileCoordinateSystem.XYZ.rawValue
                )
            return MLNRasterTileSource(identifier: id, tileURLTemplates: [template], options: options)
        case let .tileJson(url):
            guard let configUrl = URL(string: url) else {
                assertionFailure("Invalid tileJson URL: \(url)")
                return MLNRasterTileSource(identifier: id, tileURLTemplates: ["about:blank"], options: nil)
            }
            return MLNRasterTileSource(identifier: id, configurationURL: configUrl)
        case let .arcGisService(serviceUrl):
            let base = serviceUrl.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let template = "\(base)/tile/{z}/{y}/{x}"
            var options: [MLNTileSourceOption: Any] = [
                .tileSize: NSNumber(value: RasterLayerSource.defaultTileSize),
                .tileCoordinateSystem: NSNumber(value: MLNTileCoordinateSystem.XYZ.rawValue),
            ]
            return MLNRasterTileSource(identifier: id, tileURLTemplates: [template], options: options)
        }
    }
}
