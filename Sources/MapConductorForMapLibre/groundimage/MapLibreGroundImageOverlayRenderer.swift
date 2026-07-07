import CoreLocation
import Foundation
import MapConductorCore
import MapLibre

@MainActor
final class MapLibreGroundImageOverlayRenderer: AbstractGroundImageOverlayRenderer<MapLibreGroundImageHandle> {
    private weak var mapView: MLNMapView?
    private var style: MLNStyle?

    init(mapView: MLNMapView?) {
        self.mapView = mapView
        super.init()
    }

    func onStyleLoaded(_ style: MLNStyle) {
        self.style = style
    }

    func unbind() {
        style = nil
        mapView = nil
    }

    func createGroundImageSync(state: GroundImageState) -> MapLibreGroundImageHandle? {
        guard let style, let coordinates = state.bounds.toCoordinateQuad() else { return nil }

        let sourceId = sourceId(for: state.id)
        let layerId = layerId(for: state.id)

        removeSourceAndLayerIfExists(style: style, sourceId: sourceId, layerId: layerId)

        let imageSource = MLNImageSource(identifier: sourceId, coordinateQuad: coordinates, image: state.image)
        let layer = MLNRasterStyleLayer(identifier: layerId, source: imageSource)
        layer.rasterOpacity = NSExpression(forConstantValue: state.opacity.clampedOpacity)
        layer.isVisible = true

        style.addSource(imageSource)
        insertLayer(layer, into: style)

        return MapLibreGroundImageHandle(
            sourceId: sourceId,
            layerId: layerId,
            imageSource: imageSource,
            rasterLayer: layer,
            applied: state.fingerPrint().toAppliedGroundImage()
        )
    }

    func updateGroundImageSync(
        groundImage: MapLibreGroundImageHandle,
        current: GroundImageEntity<MapLibreGroundImageHandle>,
        prev: GroundImageEntity<MapLibreGroundImageHandle>
    ) -> MapLibreGroundImageHandle? {
        guard let style else { return groundImage }

        guard let imageSource = style.source(withIdentifier: groundImage.sourceId) as? MLNImageSource,
              let layer = style.layer(withIdentifier: groundImage.layerId) as? MLNRasterStyleLayer else {
            removeSourceAndLayerIfExists(style: style, sourceId: groundImage.sourceId, layerId: groundImage.layerId)
            return createGroundImageSync(state: current.state)
        }

        let finger = current.fingerPrint
        let prevFinger = groundImage.applied
        guard let coordinates = current.state.bounds.toCoordinateQuad() else { return groundImage }

        if finger.image != prevFinger.image {
            imageSource.image = current.state.image
            imageSource.coordinates = coordinates
        } else if finger.bounds != prevFinger.bounds {
            imageSource.coordinates = coordinates
        }

        if finger.opacity != prevFinger.opacity {
            layer.rasterOpacity = NSExpression(forConstantValue: current.state.opacity.clampedOpacity)
        }

        return groundImage.copy(
            imageSource: imageSource,
            rasterLayer: layer,
            applied: finger.toAppliedGroundImage()
        )
    }

    func removeGroundImageSync(entity: GroundImageEntity<MapLibreGroundImageHandle>) {
        guard let style, let handle = entity.groundImage else { return }
        removeSourceAndLayerIfExists(style: style, sourceId: handle.sourceId, layerId: handle.layerId)
    }

    override func createGroundImage(state: GroundImageState) async -> MapLibreGroundImageHandle? {
        createGroundImageSync(state: state)
    }

    override func updateGroundImageProperties(
        groundImage: MapLibreGroundImageHandle,
        current: GroundImageEntity<MapLibreGroundImageHandle>,
        prev: GroundImageEntity<MapLibreGroundImageHandle>
    ) async -> MapLibreGroundImageHandle? {
        updateGroundImageSync(groundImage: groundImage, current: current, prev: prev)
    }

    override func removeGroundImage(entity: GroundImageEntity<MapLibreGroundImageHandle>) async {
        removeGroundImageSync(entity: entity)
    }

    private func removeSourceAndLayerIfExists(style: MLNStyle, sourceId: String, layerId: String) {
        if let layer = style.layer(withIdentifier: layerId) {
            style.removeLayer(layer)
        }
        if let source = style.source(withIdentifier: sourceId) {
            style.removeSource(source)
        }
    }

    private func insertLayer(_ layer: MLNRasterStyleLayer, into style: MLNStyle) {
        if let below = findBelowLayer(style: style) {
            style.insertLayer(layer, below: below)
        } else {
            style.addLayer(layer)
        }
    }

    private func findBelowLayer(style: MLNStyle) -> MLNStyleLayer? {
        let prefixes = [
            "mapconductor-polylines-layer-",
            "mapconductor-polygons-fill-",
            "mapconductor-polygons-line-",
            "mapconductor-circles-layer-",
            "mapconductor-cluster-layer-",
            "mapconductor-markers-layer-"
        ]
        for prefix in prefixes {
            if let layer = style.layers.first(where: { $0.identifier.hasPrefix(prefix) }) {
                return layer
            }
        }
        return nil
    }

    private func sourceId(for id: String) -> String {
        "mc-gimg-src-\(styleIdPart(id))"
    }

    private func layerId(for id: String) -> String {
        "mc-gimg-lyr-\(styleIdPart(id))"
    }

    private func styleIdPart(_ id: String) -> String {
        String(id.map { ch in
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" {
                return ch
            }
            return "_"
        })
    }
}

private extension GeoRectBounds {
    func toCoordinateQuad() -> MLNCoordinateQuad? {
        guard let sw = southWest, let ne = northEast else { return nil }
        return MLNCoordinateQuadMake(
            CLLocationCoordinate2D(latitude: ne.latitude, longitude: sw.longitude),
            CLLocationCoordinate2D(latitude: sw.latitude, longitude: sw.longitude),
            CLLocationCoordinate2D(latitude: sw.latitude, longitude: ne.longitude),
            CLLocationCoordinate2D(latitude: ne.latitude, longitude: ne.longitude)
        )
    }
}

private extension GroundImageFingerPrint {
    func toAppliedGroundImage() -> AppliedGroundImage {
        AppliedGroundImage(
            bounds: bounds,
            image: image,
            opacity: opacity
        )
    }
}

private extension Double {
    var clampedOpacity: Double {
        min(max(self, 0.0), 1.0)
    }
}
