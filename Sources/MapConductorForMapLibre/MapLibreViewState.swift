import Combine
import Foundation
import MapConductorCore

/// MapLibre の state。
///
/// カメラの保持と委譲、`uiSettings`、`id` はコアの ``MapViewState`` が持つ。
/// ここに残るのは **MapLibre 固有のもの**だけ:
///  - `mapDesignType`（プロバイダ固有の型）
///  - プロバイダ型のホルダーと、それを返す `getMapViewHolder()` の絞り込み
public final class MapLibreViewState: MapViewState<MapLibreMapDesignType> {
    @Published private var _mapDesignType: MapLibreMapDesignType

    /// Provider-typed holder: `map`/`mapView` are `MLNMapView`, no cast needed.
    public private(set) var mapViewHolder: MapLibreMapViewHolder?

    public override var mapDesignType: MapLibreMapDesignType {
        get { _mapDesignType }
        set { _mapDesignType = newValue }
    }

    public init(
        id: String,
        mapDesignType: MapLibreMapDesignType = MapLibreDesign.DemoTiles,
        cameraPosition: MapCameraPosition = .Default,
        uiSettings: MapUISettings = MapUISettings()
    ) {
        self._mapDesignType = mapDesignType
        super.init(id: id, initialCameraPosition: cameraPosition, uiSettings: uiSettings)
    }

    public convenience init(
        mapDesignType: MapLibreMapDesignType = MapLibreDesign.OsmBright,
        cameraPosition: MapCameraPosition = .Default,
        uiSettings: MapUISettings = MapUISettings()
    ) {
        self.init(id: UUID().uuidString, mapDesignType: mapDesignType, cameraPosition: cameraPosition, uiSettings: uiSettings)
    }

    /// アプリが `state.getMapViewHolder()?.map` で `MLNMapView` を取れる形を保つための絞り込み。
    public override func getMapViewHolder() -> AnyMapViewHolder? {
        mapViewHolder.map { AnyMapViewHolder($0) }
    }

    func setController(_ controller: (any MapViewControllerProtocol)?) {
        attachController(controller)
    }

    func setMapViewHolder(_ holder: MapLibreMapViewHolder?) {
        mapViewHolder = holder
    }

    func updateCameraPosition(_ cameraPosition: MapCameraPosition) {
        setCameraPositionInternal(cameraPosition)
    }
}
