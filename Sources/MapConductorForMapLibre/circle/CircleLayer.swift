import Foundation
import MapLibre

/// Draws circles as "fill (MLNFillStyleLayer) + stroke (MLNLineStyleLayer)".
///
/// Circles were previously drawn with a native MLNCircleStyleLayer (screen-pixel radius
/// expression), but that cannot express geodesic circles (rings equidistant along great
/// circles, which are not perfect circles in Mercator). Instead the ring polygon produced by
/// the core `circleToRing` is rendered, matching the polygon layer plumbing.
final class CircleLayer {
    enum Prop {
        static let fillColor = "fillColor"
        static let strokeColor = "strokeColor"
        static let strokeWidth = "strokeWidth"
        static let circleId = "circle_id"
    }

    let sourceId: String
    /// Fill layer keeps the historical `layerId` so existing ordering anchors stay valid.
    let layerId: String
    let strokeLayerId: String

    private(set) var source: MLNShapeSource?
    private(set) var fillLayer: MLNFillStyleLayer?
    private(set) var strokeLayer: MLNLineStyleLayer?

    init(sourceId: String, layerId: String) {
        self.sourceId = sourceId
        self.layerId = layerId
        self.strokeLayerId = "\(layerId)-stroke"
    }

    func ensureAdded(to style: MLNStyle) {
        let existingSource = style.source(withIdentifier: sourceId) as? MLNShapeSource
        let existingFill = style.layer(withIdentifier: layerId) as? MLNFillStyleLayer
        let existingStroke = style.layer(withIdentifier: strokeLayerId) as? MLNLineStyleLayer

        if let existingSource, let existingFill, let existingStroke {
            source = existingSource
            fillLayer = existingFill
            strokeLayer = existingStroke
            return
        }

        let source = existingSource ?? MLNShapeSource(identifier: sourceId, features: [], options: nil)
        if existingSource == nil {
            style.addSource(source)
        }

        let fillLayer = existingFill ?? MLNFillStyleLayer(identifier: layerId, source: source)
        if existingFill == nil {
            fillLayer.fillColor = NSExpression(forKeyPath: Prop.fillColor)
            style.addLayer(fillLayer)
        }

        let strokeLayer = existingStroke ?? MLNLineStyleLayer(identifier: strokeLayerId, source: source)
        if existingStroke == nil {
            strokeLayer.lineColor = NSExpression(forKeyPath: Prop.strokeColor)
            strokeLayer.lineWidth = NSExpression(forKeyPath: Prop.strokeWidth)
            strokeLayer.lineJoin = NSExpression(forConstantValue: "round")
            strokeLayer.lineCap = NSExpression(forConstantValue: "round")
            style.insertLayer(strokeLayer, above: fillLayer)
        }

        self.source = source
        self.fillLayer = fillLayer
        self.strokeLayer = strokeLayer
    }

    func setFeatures(_ features: [MLNPolygonFeature]) {
        guard let source else { return }
        source.shape = MLNShapeCollectionFeature(shapes: features)
    }

    func remove(from style: MLNStyle) {
        if let strokeLayer {
            style.removeLayer(strokeLayer)
        }
        if let fillLayer {
            style.removeLayer(fillLayer)
        }
        if let source {
            style.removeSource(source)
        }
        self.strokeLayer = nil
        self.fillLayer = nil
        self.source = nil
    }
}
