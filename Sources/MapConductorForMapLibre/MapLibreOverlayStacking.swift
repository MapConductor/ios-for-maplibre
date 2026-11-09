import Foundation
import MapLibre
@_spi(MapConductorDriver) import MapConductorCore

/// オーバーレイのレイヤを、重なり順の帯（``OverlayBand``）の位置へ差し込む。
///
/// 下から ラスター < グラウンドイメージ < ポリゴン < サークル < ポリライン < マーカー。
/// 追加した順・送り直した順・デザイン変更の後の作り直しの順に左右されない。
/// 以前は各描画担当が `style.addLayer`（一番上に積む）で足していたので、
/// 後から足したもの（clearOverlays の後に送り直したポリゴンなど）が上に来ていた。
///
/// ラスターだけはベースマップのラベルの下に置く（ラベルを覆わないため。従来どおり）。
/// それ以外はラベルより上。帯の中は zIndex（ラスターのみレイヤ単位。ほかは 1 枚のレイヤの
/// sort key で並ぶ）、同じなら後から足したものが上。
enum MapLibreOverlayStacking {
    static func insert(
        _ layer: MLNStyleLayer,
        _ key: OverlayStackKey,
        into style: MLNStyle,
        rasterZIndex: [String: Int] = [:]
    ) {
        let layers = style.layers
        let keys: [OverlayStackKey?] = layers.map { existing in
            guard let band = OverlayStacking.band(ofStyleLayerId: existing.identifier) else { return nil }
            return OverlayStackKey(band, zIndex: band == .rasterLayer ? (rasterZIndex[existing.identifier] ?? 0) : 0)
        }
        let ceiling = key.band == .rasterLayer ? firstBasemapLabelIndex(layers) : nil
        let index = OverlayStacking.insertionIndex(for: key, among: keys, ceiling: ceiling)
        if index >= layers.count {
            style.addLayer(layer)
        } else {
            style.insertLayer(layer, below: layers[index])
        }
    }

    /// ベースマップの最初のラベル（symbol レイヤ）。MapConductor のマーカーも symbol なので除く。
    private static func firstBasemapLabelIndex(_ layers: [MLNStyleLayer]) -> Int? {
        layers.firstIndex { $0 is MLNSymbolStyleLayer && OverlayStacking.band(ofStyleLayerId: $0.identifier) == nil }
    }
}
