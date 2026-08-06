import Foundation
import MapConductorCore
import MapLibre

/// `RasterLayerState` の `userAgent` / `extraHeaders` を MapLibre のリクエストに載せる。
///
/// MapLibre はリクエスト送出前のフックを 1 つだけ公開している:
///
/// ```objc
/// @protocol MLNNetworkConfigurationDelegate
/// - (NSMutableURLRequest *)willSendRequest:(NSMutableURLRequest *)request;
/// ```
///
/// 差し込み先の `MLNNetworkConfiguration.sharedManager` は**プロセス全体で 1 つ**。
/// 地図が複数あっても、`ios-for-maptiler` が同居していても壊れないよう、この型は
/// シングルトンにし、規則そのものは core の ``RasterHeaderRuleSet/shared`` に置く。
/// MapTiler 側の同等品も同じ置き場を見るので、どちらの delegate が最終的に
/// `sharedManager` に載っていても結果が変わらない。
///
/// ヘッダはラスタタイルの**配信ホスト宛にだけ**載せる。全リクエストに載せると、
/// ラスタレイヤを 1 枚置いただけでベースマップのスタイル取得の User-Agent まで
/// 書き換わる（`RasterLayerState.userAgent` の既定値は空ではない）。
///
/// - Note: `willSendRequest:` は MapLibre のヘッダで `:nodoc:` かつ experimental と
///   注記されている。実際に呼ばれることは `RasterHeaderUITests` が実機で固定している。
final class MapLibreRasterHeaderInjector: NSObject, MLNNetworkConfigurationDelegate {
    static let shared = MapLibreRasterHeaderInjector()

    private override init() {
        super.init()
    }

    /// 登録元 1 つ分の規則を差し替え、必要に応じてフックを着脱する。
    func apply(states: [RasterLayerState], owner: AnyObject) {
        RasterHeaderRuleSet.shared.setRules(
            RasterHeaderRuleSet.makeRules(from: states),
            owner: owner
        )
        syncDelegate()
    }

    /// 登録元 1 つ分の規則を外す。
    func remove(owner: AnyObject) {
        RasterHeaderRuleSet.shared.removeRules(owner: owner)
        syncDelegate()
    }

    /// 規則が無いときはフックを外して MapLibre 既定の挙動に戻す。
    /// 付けっぱなしにすると、ヘッダを一切指定していないアプリにも余計な処理が挟まる。
    private func syncDelegate() {
        if RasterHeaderRuleSet.shared.isEmpty {
            if MLNNetworkConfiguration.sharedManager.delegate === self {
                MLNNetworkConfiguration.sharedManager.delegate = nil
            }
        } else {
            MLNNetworkConfiguration.sharedManager.delegate = self
        }
    }

    /// - Important: セレクタ名を明示している。`MLNNetworkConfigurationDelegate` の
    ///   メソッドはすべて `@optional` なので、Swift 側の名前が `willSendRequest:` に
    ///   束ならなくてもコンパイルは通り、**黙って呼ばれないだけ**になる。
    @objc(willSendRequest:)
    func willSend(_ request: NSMutableURLRequest) -> NSMutableURLRequest {
        guard let url = request.url,
              let match = RasterHeaderRuleSet.shared.headers(for: url)
        else { return request }

        if let userAgent = match.userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        for (key, value) in match.extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }
}
