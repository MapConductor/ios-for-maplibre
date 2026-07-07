import Foundation
import MapConductorCore
import MapLibre

final class MapLibreGroundImageHandle {
    let sourceId: String
    let layerId: String
    let imageSource: MLNImageSource
    let rasterLayer: MLNRasterStyleLayer
    let applied: AppliedGroundImage

    init(
        sourceId: String,
        layerId: String,
        imageSource: MLNImageSource,
        rasterLayer: MLNRasterStyleLayer,
        applied: AppliedGroundImage
    ) {
        self.sourceId = sourceId
        self.layerId = layerId
        self.imageSource = imageSource
        self.rasterLayer = rasterLayer
        self.applied = applied
    }

    func copy(
        imageSource: MLNImageSource? = nil,
        rasterLayer: MLNRasterStyleLayer? = nil,
        applied: AppliedGroundImage? = nil
    ) -> MapLibreGroundImageHandle {
        MapLibreGroundImageHandle(
            sourceId: sourceId,
            layerId: layerId,
            imageSource: imageSource ?? self.imageSource,
            rasterLayer: rasterLayer ?? self.rasterLayer,
            applied: applied ?? self.applied
        )
    }
}

struct AppliedGroundImage: Equatable {
    let bounds: Int
    let image: Int
    let opacity: Int
}
