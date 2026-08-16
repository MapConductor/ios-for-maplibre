import CoreLocation
import MapLibre
// FlyToZoomArc はドライバー実装点なので @_spi 越しに取る。
@_spi(MapConductorDriver) import MapConductorCore
import QuartzCore
import UIKit

final class MapLibreViewController: MapViewControllerProtocol {
    let holder: AnyMapViewHolder
    let typedHolder: MapLibreMapViewHolder
    let coroutine = CoroutineScope()

    /// この地図に紐づくオーバーレイコントローラの登録簿。
    /// 拡張モジュール（ヒートマップ、マーカークラスタリング等）がここに登録して
    /// カメラ変更を受け取る。`MapViewControllerProtocol` の要件。
    let overlayControllers = OverlayControllerRegistry()
    private weak var mapView: MLNMapView?
    private var cameraAnimator: CameraAnimator?
    private(set) var lastLogicalTilt: Double? = nil

    private var cameraMoveStartListener: OnCameraMoveHandler?
    private var cameraMoveListener: OnCameraMoveHandler?
    private var cameraMoveEndListener: OnCameraMoveHandler?
    private var mapClickListener: OnMapEventHandler?
    private var mapLongClickListener: OnMapEventHandler?
    private var mapInitializedListener: OnMapInitializedHandler?

    /// パン範囲の制限に使う。
    ///
    /// MapLibre iOS でのパン範囲制限は 2 系統に分かれる:
    ///
    /// - **ジェスチャー**: `MLNMapViewDelegate` の
    ///   `mapView(_:shouldChangeFrom:to:reason:)` で範囲外への変更を拒否する
    ///   （``shouldAllowGestureCameraChange(from:to:)``）。境界で滑らかに止まるので、
    ///   android-for-maplibre の `setLatLngBoundsForCameraTarget` に最も近い挙動になる。
    /// - **プログラム的な移動**: 上記デリゲートはヘッダに明記されているとおり
    ///   `centerCoordinate` 設定や `flyToCamera` では呼ばれないため、カメラ停止時に
    ///   このクランプで矩形内へ引き戻す（android-sdk の HERE/ArcGIS/TomTom と同じ方式）。
    ///
    /// ズームはネイティブの `minimumZoomLevel` / `maximumZoomLevel` で制限する。
    let cameraRestrictionClamp = CameraRestrictionClamp()

    /// ジェスチャーによるカメラ変更を許可してよいか。
    ///
    /// 制限矩形の外へ出る変更だけを拒否する。すでに範囲外にいる場合は許可する
    /// （拒否すると範囲外に取り残されて二度と戻れなくなるため。復帰は停止時の
    /// クランプが行う）。
    func shouldAllowGestureCameraChange(
        from oldCenter: CLLocationCoordinate2D,
        to newCenter: CLLocationCoordinate2D
    ) -> Bool {
        guard let bounds = cameraRestrictionClamp.current?.bounds,
              let sw = bounds.southWest,
              let ne = bounds.northEast else { return true }

        let south = min(sw.latitude, ne.latitude)
        let north = max(sw.latitude, ne.latitude)
        let west = min(sw.longitude, ne.longitude)
        let east = max(sw.longitude, ne.longitude)

        func isInside(_ c: CLLocationCoordinate2D) -> Bool {
            c.latitude >= south && c.latitude <= north
                && c.longitude >= west && c.longitude <= east
        }

        if isInside(newCenter) { return true }
        return !isInside(oldCenter)
    }

    init(mapView: MLNMapView) {
        self.mapView = mapView
        let typedHolder = MapLibreMapViewHolder(mapView: mapView)
        self.typedHolder = typedHolder
        self.holder = AnyMapViewHolder(typedHolder)
    }

    func clearOverlays() async {
        guard let mapView = mapView else { return }
        if let annotations = mapView.annotations {
            mapView.removeAnnotations(annotations)
        }
    }

    func setCameraMoveStartListener(listener: OnCameraMoveHandler?) {
        cameraMoveStartListener = listener
    }

    func setCameraMoveListener(listener: OnCameraMoveHandler?) {
        cameraMoveListener = listener
    }

    func setCameraMoveEndListener(listener: OnCameraMoveHandler?) {
        cameraMoveEndListener = listener
    }

    func setMapClickListener(listener: OnMapEventHandler?) {
        mapClickListener = listener
    }

    func setMapLongClickListener(listener: OnMapEventHandler?) {
        mapLongClickListener = listener
    }

    func setMapInitializedListener(listener: OnMapInitializedHandler?) {
        mapInitializedListener = listener
    }

    func moveCamera(position: MapCameraPosition) {
        guard let mapView = mapView else { return }
        lastLogicalTilt = position.tilt
        let cameraState = position.toMapLibreCameraState()

        // ★ pitch を先に、zoom を後に当てる。順序を逆にすると**傾けるたびに地図が遠ざかる**。
        //
        // `MLNMapCamera` が持っているのは真下方向の距離 `altitude` で、実際の縮尺を決めるのは
        // 視点までの距離 `viewingDistance = altitude / cos(pitch)` のほう（ヘッダに
        // 「altitude を書くと pitch から viewingDistance が計算し直される」と書いてある）。
        // `mapView.camera` は pitch 0 のときの altitude を持っているので、pitch だけ書き換えると
        // altitude が据え置かれ、viewingDistance が 1/cos(pitch) 倍に伸びる ＝ ズームが下がる。
        //
        // android は `CameraPosition(target, zoom, tilt, bearing)` を 1 つ渡すので zoom が守られる。
        // iOS も pitch を当ててから `setCenter(zoomLevel:)` で zoom を入れ直せば同じになる
        // （`setCenter` は pitch を触らない）。
        //
        // Note: MLNMapView.camera is a copy; mutating mapView.camera.pitch does not affect the map.
        let camera = mapView.camera
        camera.centerCoordinate = cameraState.center
        camera.heading = cameraState.bearing
        camera.pitch = cameraState.tilt
        mapView.setCamera(camera, animated: false)

        mapView.setCenter(
            cameraState.center,
            zoomLevel: cameraState.zoom,
            direction: cameraState.bearing,
            animated: false
        )
    }

    func animateCamera(position: MapCameraPosition, duration: Long) {
        guard let mapView = mapView else { return }
        let durationSeconds = max(0.0, Double(duration) / 1000.0)
        guard durationSeconds > 0 else {
            moveCamera(position: position)
            return
        }

        cameraAnimator?.stop()
        let from = mapView.toMapCameraPosition(logicalTiltHint: lastLogicalTilt)
        lastLogicalTilt = position.tilt
        cameraAnimator = CameraAnimator(
            mapView: mapView,
            from: from,
            to: position,
            duration: durationSeconds
        )
        cameraAnimator?.start()
    }

    func setCameraRestriction(_ restriction: CameraRestriction?) {
        cameraRestrictionClamp.set(restriction)
        guard let mapView = mapView else { return }
        // ズームはネイティブ API で制限する。統一ズーム（Google 準拠）を MapLibre ズームへ変換。
        // preference は解除 API が無いため、未指定時は既定の下限/上限を渡す
        // （android-for-maplibre と同じ扱い）。
        mapView.minimumZoomLevel = restriction?.minZoom
            .map { MapLibreZoomAltitudeConverter.googleZoomToMaplibreZoom($0) }
            ?? 0.0
        mapView.maximumZoomLevel = restriction?.maxZoom
            .map { MapLibreZoomAltitudeConverter.googleZoomToMaplibreZoom($0) }
            ?? 22.0
    }

    /// カメラ停止時にパン範囲の制限違反を補正する。違反があれば `true`（通常の
    /// カメラ停止処理はスキップし、再適用後のイベントで進む）。
    ///
    /// ジェスチャーは ``shouldAllowGestureCameraChange(from:to:)`` が境界で止めるので、
    /// ここに来るのは主にプログラム的な `moveCameraTo` による範囲外移動。
    func applyCameraRestrictionCorrectionIfNeeded(_ current: MapCameraPosition) -> Bool {
        guard let corrected = cameraRestrictionClamp.correction(for: current) else { return false }
        moveCamera(position: corrected)
        return true
    }

    func fitBounds(bounds: GeoRectBounds, padding: Int) {
        guard let mapView = mapView,
              let sw = bounds.southWest,
              let ne = bounds.northEast else { return }
        let coordinateBounds = MLNCoordinateBoundsMake(
            CLLocationCoordinate2D(latitude: sw.latitude, longitude: sw.longitude),
            CLLocationCoordinate2D(latitude: ne.latitude, longitude: ne.longitude)
        )
        let edgePadding = UIEdgeInsets(top: CGFloat(padding), left: CGFloat(padding), bottom: CGFloat(padding), right: CGFloat(padding))
        mapView.setVisibleCoordinateBounds(coordinateBounds, edgePadding: edgePadding, animated: false)
    }

    func notifyCameraMoveStart(_ cameraPosition: MapCameraPosition) {
        cameraMoveStartListener?(cameraPosition)
    }

    func notifyCameraMove(_ cameraPosition: MapCameraPosition) {
        cameraMoveListener?(cameraPosition)
    }

    func notifyCameraMoveEnd(_ cameraPosition: MapCameraPosition) {
        // 登録済みオーバーレイ（拡張モジュール含む）へ伝播する。
        overlayControllers.dispatchCameraChanged(cameraPosition)
        cameraMoveEndListener?(cameraPosition)
    }

    func notifyMapClick(_ point: GeoPoint) {
        mapClickListener?(point)
    }

    func notifyMapLongClick(_ point: GeoPoint) {
        mapLongClickListener?(point)
    }

    func notifyMapInitialized() {
        mapInitializedListener?(.MapCreated)
    }
}

private final class CameraAnimator {
    private weak var mapView: MLNMapView?
    private let from: MapCameraPosition
    private let to: MapCameraPosition
    private let duration: TimeInterval
    /// 中心とズームの補間。van Wijk（＝ android-for-maplibre の
    /// `map.animateCamera` が落ちる `NativeMap.flyTo` と同じ式）。
    /// ``FlyToZoomArc`` の説明を読むこと。
    private let arc: FlyToZoomArc
    private var displayLink: CADisplayLink?
    private let startTime: CFTimeInterval

    init(
        mapView: MLNMapView,
        from: MapCameraPosition,
        to: MapCameraPosition,
        duration: TimeInterval
    ) {
        self.mapView = mapView
        self.from = from
        self.to = to
        self.duration = max(duration, 0.01)
        self.startTime = CACurrentMediaTime()

        let bounds = mapView.bounds
        let viewport = max(Double(max(bounds.width, bounds.height)), 1.0)
        self.arc = FlyToZoomArc(from: from, to: to, viewportSizePixels: viewport)
    }

    func start() {
        let displayLink = CADisplayLink(target: self, selector: #selector(step(_:)))
        self.displayLink = displayLink
        displayLink.add(to: .main, forMode: .common)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ displayLink: CADisplayLink) {
        guard let mapView = mapView else {
            stop()
            return
        }

        let elapsed = CACurrentMediaTime() - startTime
        let linear = min(1.0, elapsed / duration)
        let t = easeInOut(linear)

        // 中心とズームは van Wijk が決める。**`t` で素朴に補間しないこと**
        // （中心は等速でもズームだけ弧を描く、という組み合わせは移動が破綻して見える）。
        let centerT = arc.centerFraction(at: t)
        let latitude = lerp(from.position.latitude, to.position.latitude, centerT)
        let longitude = lerp(from.position.longitude, to.position.longitude, centerT)
        let zoom = arc.zoom(at: t)
        // bearing / tilt は距離と無関係なので従来どおり時間で補間する。
        let bearing = lerpAngle(from.bearing, to.bearing, t)
        let tilt = lerp(from.tilt, to.tilt, t)

        let currentPos = MapCameraPosition(
            position: GeoPoint(latitude: latitude, longitude: longitude, altitude: 0),
            zoom: zoom,
            bearing: bearing,
            tilt: tilt
        )
        let cameraState = currentPos.toMapLibreCameraState()
        // pitch を先に、zoom を後に。逆にすると傾けるたびに地図が遠ざかる
        // （理由は `MapLibreViewController.moveCamera` のコメント）。
        let camera = mapView.camera
        camera.centerCoordinate = cameraState.center
        camera.heading = cameraState.bearing
        camera.pitch = cameraState.tilt
        mapView.setCamera(camera, animated: false)
        mapView.setCenter(
            cameraState.center,
            zoomLevel: cameraState.zoom,
            direction: cameraState.bearing,
            animated: false
        )

        if t >= 1.0 {
            stop()
        }
    }

    private func lerp(_ from: Double, _ to: Double, _ t: Double) -> Double {
        from + (to - from) * t
    }

    private func lerpAngle(_ from: Double, _ to: Double, _ t: Double) -> Double {
        let delta = ((to - from + 540).truncatingRemainder(dividingBy: 360)) - 180
        return from + delta * t
    }

    private func easeInOut(_ t: Double) -> Double {
        guard t > 0 && t < 1 else { return t }
        return t * t * (3 - 2 * t)
    }

    /// ジェスチャの ON/OFF を地図へ適用する。
    /// android-sdk の `applyUISettings(settings:)` と同じ位置づけ。
    /// 初回適用はビュー生成時（`makeUIView`）に行い、以降の変更がここを通る。
    func applyUISettings(_ settings: MapUISettings) {
        guard let mapView else { return }
        mapView.isScrollEnabled = settings.scrollGesture
        mapView.isZoomEnabled = settings.zoomGesture
        mapView.isRotateEnabled = settings.rotateGesture
        mapView.isPitchEnabled = settings.tiltGesture
    }

}
