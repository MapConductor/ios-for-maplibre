import MapConductorCore
import MapLibre

@MainActor
final class MapLibreRasterLayerController: RasterLayerController<MapLibreRasterLayer, MapLibreRasterLayerOverlayRenderer> {
    private weak var mapView: MLNMapView?
    private weak var loadedStyle: MLNStyle?

    /// スタイルが載るまでレイヤ追加を保留する門。
    ///
    /// スタイルを差し替えると、ランタイムに足したソースとレイヤはすべて捨てられる。
    /// `MapViewScope` のコレクタは**メンバーシップが変わったときにしか**流してこないので、
    /// 作り直すには最後の一式を覚えておく必要がある。門が `latest` として持っている。
    private lazy var styleGate = DeferredUntilReady<[RasterLayerState]> { [weak self] states in
        Task { [weak self] in await self?.applyToRenderer(states) }
    }

    init(mapView: MLNMapView?) {
        self.mapView = mapView
        let rasterManager = RasterLayerManager<MapLibreRasterLayer>()
        let renderer = MapLibreRasterLayerOverlayRenderer(mapView: mapView)
        super.init(rasterLayerManager: rasterManager, renderer: renderer)
    }

    func onStyleLoaded(_ style: MLNStyle) {
        let styleChanged = loadedStyle !== style
        loadedStyle = style
        renderer.onStyleLoaded(style)

        // 新しい MLNStyle は古いスタイルに登録したハンドルを持たない。
        // 覚えているハンドルを捨てて、全レイヤを作り直させる。
        if styleChanged {
            rasterLayerManager.clear()
        }

        styleGate.markReady()
    }

    /// ヘッダはレイヤを足す**前に**登録する。あとからだと最初のタイル要求が
    /// ヘッダ無しで飛び、認証が要るサーバでは初回だけ 401 になる。
    override func add(data: [RasterLayerState]) async {
        MapLibreRasterHeaderInjector.shared.apply(states: data, owner: self)
        styleGate.submit(data)
    }

    override func update(state: RasterLayerState) async {
        let merged = (styleGate.latest ?? []).map { $0.id == state.id ? state : $0 }
        MapLibreRasterHeaderInjector.shared.apply(states: merged, owner: self)
        styleGate.submit(merged)
        guard styleGate.isReady else { return }
        await super.update(state: state)
    }

    override func clear() async {
        MapLibreRasterHeaderInjector.shared.remove(owner: self)
        styleGate.submit([])
        await super.clear()
    }

    // カメラ変更で非同期処理を起こさない。ラスタレイヤはカメラに追従する必要がない。
    override func onCameraChanged(mapCameraPosition: MapCameraPosition) async {
    }

    func unbind() {
        MapLibreRasterHeaderInjector.shared.remove(owner: self)
        styleGate.reset()
        loadedStyle = nil
        renderer.unbind()
        mapView = nil
        destroy()
    }

    /// `super.add` はクロージャから直接呼べない（escaping クロージャで `super` を
    /// 捕まえられない）ので、門からはこのメソッド経由で入る。
    private func applyToRenderer(_ states: [RasterLayerState]) async {
        await super.add(data: states)
    }
}
