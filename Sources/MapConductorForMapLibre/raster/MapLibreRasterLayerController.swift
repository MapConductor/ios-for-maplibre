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

    /// Layers the SDK adds itself (polygon tiles) through `upsert`, kept so they
    /// can be added again: a new style drops every runtime layer, and these are
    /// not in the app's list the gate replays.
    private var upserted: [String: RasterLayerState] = [:]

    /// `upsert` callers whose layer could not go on the map yet, by layer id.
    /// They return once `onStyleLoaded` has added it.
    private var awaitingStyle: [String: [CheckedContinuation<Void, Never>]] = [:]

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
        let replay = Array(upserted.values)
        let waiting = awaitingStyle
        awaitingStyle.removeAll()
        if !replay.isEmpty || !waiting.isEmpty {
            Task { [weak self] in
                for state in replay { await self?.applyUpsert(state) }
                for continuation in waiting.values.joined() { continuation.resume() }
            }
        }
    }

    /// Before the style is ready there is nowhere to add the layer; it is added
    /// when the style loads.
    ///
    /// Returns once the layer is on the map, which can be after that load: the
    /// caller takes the return as "on the map" (PolygonTiler reports the tiled
    /// polygons' `onAdded` then). The style is also missing while a new map
    /// design loads, when the layer added here is dropped with the old style.
    override func upsert(state: RasterLayerState) async {
        upserted[state.id] = state
        if styleGate.isReady {
            await super.upsert(state: state)
            if renderer.isStyleLoaded { return }
        }
        await withCheckedContinuation { continuation in
            awaitingStyle[state.id, default: []].append(continuation)
        }
    }

    override func removeById(_ id: String) async {
        upserted.removeValue(forKey: id)
        awaitingStyle.removeValue(forKey: id)?.forEach { $0.resume() }
        await super.removeById(id)
    }

    private func applyUpsert(_ state: RasterLayerState) async {
        // Replaced or removed while waiting.
        guard upserted[state.id] === state else { return }
        await super.upsert(state: state)
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
        upserted.removeAll()
        let waiting = awaitingStyle
        awaitingStyle.removeAll()
        for continuation in waiting.values.joined() { continuation.resume() }
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
