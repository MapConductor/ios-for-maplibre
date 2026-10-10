import CMapLibreStyleTry
import Foundation
import MapConductorCore
import MapLibre

/**
 Changes a loaded MapLibre style in place.

 The seven calls ``StyleMutationTarget`` asks for, against MapLibre's style
 API. Everything above them — what a mutation means, which can be skipped,
 keeping one bad property from costing the rest — is `applyStyleMutations`
 in core, shared with every other provider.

 ## Why this is the awkward one

 Mapbox here and the MapTiler bridge both take a style property by its spec
 name with any JSON value. MapLibre on iOS does not: every property is a
 typed Objective-C property on a typed layer class — `lineColor` on
 `MLNLineStyleLayer`, `textFontSize` on `MLNSymbolStyleLayer` — and there is
 no call that takes `"line-color"` as a string.

 So this adapter reaches them by name through key-value coding, which needs
 two things the spec does not provide:

 - **The Objective-C name.** Usually the spec key in camel case, but
   thirty-eight properties were renamed when the SDK was written
   (`icon-size` is `iconScale`, `text-field` is `text`, `line-dasharray` is
   `lineDashPattern`). Those are in ``renamed``; everything else is derived.
 - **Proof the property exists.** A key-value set against a name the object
   does not have raises an Objective-C exception, so the setter is checked
   with `responds(to:)` first and a key MapLibre has no property for comes
   back unapplied. This is the one provider where that happens, and it is
   why a mutation set reports what it could not do instead of assuming it
   worked.

 Checking the name is not enough on its own: building an expression from
 style JSON this SDK's Objective-C bridge does not model raises too, and
 Swift cannot catch an `NSException`. Both calls therefore go through
 `CMapLibreStyleTry`, so a style MapLibre does not fully understand is
 reported rather than fatal.

 ## Colours

 MapLibre's colour properties hold a `UIColor`, not the `"#rrggbb"` the
 style spec writes, and a plain string constant is refused
 (`-[NSTaggedPointerString mgl_color]: unrecognized selector`). The
 expression route that looks like the answer — `["to-color", "#rrggbb"]` —
 is worse: Foundation on current iOS refuses `CAST(x, 'UIColor')` and ends
 the process rather than raising.

 So a constant colour is parsed here. It only has to read two syntaxes,
 because the compiler canonicalises every colour that crosses the boundary —
 `hsl()`, a CSS name, `#rgb` all leave it as `#rrggbb` or
 `rgba(r,g,b,a)` — and that is deliberately for this adapter's sake. A
 colour in some other form comes back unapplied rather than being guessed
 at.

 A colour *inside* an expression needs none of this: MapLibre's own
 expression bridge turns the leaves into `UIColor` on the way in.
 */
struct MapLibreStyleMutationTarget: StyleMutationTarget {
    /**
     The loaded style, read through a closure rather than captured.

     Every design change replaces it, and a target holding the old one would
     patch a style the map has already dropped.
     */
    let style: () -> MLNStyle?

    /**
     Whether the style on screen is the document these deltas are for.

     Not `style() != nil`. MapLibre keeps the outgoing `MLNStyle` alive and
     reachable while the next one loads, so "there is a style" stays true
     across the very moment a vector style hands over a new document -- and
     every delta compiled for the incoming document then finds none of its
     layers in the outgoing one and comes back refused. The provider
     answers the narrower question.
     */
    private let ready: () -> Bool

    var isReady: Bool { ready() }

    init(style: @escaping () -> MLNStyle?, isReady: @escaping () -> Bool) {
        self.style = style
        self.ready = isReady
    }

    func hasLayer(_ layerId: String) -> Bool {
        style()?.layer(withIdentifier: layerId) != nil
    }

    func setPaint(_ layerId: String, _ key: String, _ valueJson: String) throws {
        guard let layer = style()?.layer(withIdentifier: layerId) else { return }
        try set(layer, key, valueJson)
    }

    /// MapLibre does not split paint from layout here either: both are
    /// properties on the layer.
    func setLayout(_ layerId: String, _ key: String, _ valueJson: String) throws {
        guard let layer = style()?.layer(withIdentifier: layerId) else { return }
        // `visibility` is the one layout key that is not an expression.
        if key == "visibility" {
            layer.isVisible = try text(of: valueJson) != "none"
            return
        }
        try set(layer, key, valueJson)
    }

    func setFilter(_ layerId: String, _ filterJson: String) throws {
        guard let layer = style()?.layer(withIdentifier: layerId) else { return }
        // Only a layer over a source can be filtered; background, raster and
        // hillshade cannot, which the caller reports as not applied --
        // correct, because they cannot be.
        guard let vector = layer as? MLNVectorStyleLayer else {
            throw Unsupported.noFilter(layerId)
        }
        guard let value = try json(of: filterJson) else {
            vector.predicate = nil
            return
        }
        var message: NSString?
        guard let predicate = MCMapLibrePredicate(value, &message) else {
            throw Unsupported.refused("filter", message as String? ?? "")
        }
        vector.predicate = predicate
    }

    func setZoomRange(_ layerId: String, _ minZoom: Double, _ maxZoom: Double) throws {
        guard let layer = style()?.layer(withIdentifier: layerId) else { return }
        layer.minimumZoomLevel = Float(minZoom)
        layer.maximumZoomLevel = Float(maxZoom)
    }

    func addLayer(_ layerId: String, _ layerJson: String, _ beforeId: String?) throws {
        guard let style = style() else { return }
        // Already there: the style was reloaded and the whole set is going
        // back on.
        guard style.layer(withIdentifier: layerId) == nil else { return }
        guard let document = try json(of: layerJson) as? [String: Any] else {
            throw Unsupported.notALayer(layerId)
        }
        // MapLibre builds layers from typed constructors; there is no "add
        // this JSON" call. The compiler only ever adds one kind of layer --
        // a background under a style that has none -- so that is the one
        // kind handled, and anything else is refused rather than guessed at.
        guard document["type"] as? String == "background" else {
            throw Unsupported.notABackground(layerId)
        }
        let background = MLNBackgroundStyleLayer(identifier: layerId)
        for (key, value) in document["paint"] as? [String: Any] ?? [:] {
            try set(background, key, StyleMutation.jsonText(of: value))
        }
        if let beforeId, let sibling = style.layer(withIdentifier: beforeId) {
            style.insertLayer(background, below: sibling)
        } else {
            style.addLayer(background)
        }
    }

    func removeLayer(_ layerId: String) throws {
        guard let style = style(), let layer = style.layer(withIdentifier: layerId) else { return }
        style.removeLayer(layer)
    }

    // MARK: - Reaching a typed property by its spec name

    func set(_ layer: MLNStyleLayer, _ key: String, _ valueJson: String) throws {
        let name = Self.renamed[key] ?? Self.camelCased(key)
        // Asked first, because a key this SDK has no property for is the
        // ordinary case here -- the style spec is larger than the
        // Objective-C surface -- and `noProperty` is what the caller reports.
        guard layer.responds(to: Self.setter(for: name)) else {
            throw Unsupported.noProperty(key)
        }
        var message: NSString?
        guard MCMapLibreSetValue(layer, name, try expression(key, valueJson), &message) else {
            throw Unsupported.refused(key, message as String? ?? "")
        }
    }

    /// `line-color` → `lineColor`. The rule for every property the SDK did
    /// not rename.
    static func camelCased(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard let first = parts.first else { return key }
        return ([String(first)] + parts.dropFirst().map(\.capitalized)).joined()
    }

    private static func setter(for name: String) -> Selector {
        Selector("set\(name.prefix(1).uppercased())\(name.dropFirst()):")
    }

    /**
     A mutation's value, which travels as JSON text, as the `NSExpression`
     MapLibre wants.

     `nil` for a value that is JSON `null`: every one of these properties is
     `null_resettable`, so that is how a renderer is told to go back to the
     spec default.
     */
    private func expression(_ key: String, _ valueJson: String) throws -> NSExpression? {
        guard let value = try json(of: valueJson) else { return nil }
        // MapLibre's colour properties hold a `UIColor`, and the spec writes
        // a string. `to-color` gets it parsed by MapLibre rather than here.
        // A constant colour cannot go through the expression bridge at all;
        // everything else can, including a colour inside an expression.
        if key.hasSuffix("-color"), let text = value as? String {
            guard let colour = Self.colour(text) else {
                throw Unsupported.refused(key, "\(text) is not a colour this can read")
            }
            return NSExpression(forConstantValue: colour)
        }
        var message: NSString?
        guard let expression = MCMapLibreExpression(value, &message) else {
            // Valid style JSON this SDK's Objective-C bridge does not model
            // -- a newer operator, usually. Reported, not fatal.
            throw Unsupported.refused(key, message as String? ?? "")
        }
        return expression
    }

    /**
     A style colour as the `UIColor` MapLibre wants.

     `#rrggbb` and `rgba(r,g,b,a)` are what the compiler emits, including for
     a colour it read back out of the author's document, so those two are
     what this has to read. `#rgb`, `#rgba`, `#rrggbbaa` and `rgb()` cost
     nothing to accept as well. Anything else answers `nil`, and the caller
     reports the property as not applied — better than a colour invented
     here.
     */
    static func colour(_ text: String) -> UIColor? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.hasPrefix("#") {
            return hex(String(trimmed.dropFirst()))
        }
        guard trimmed.hasPrefix("rgb"), let open = trimmed.firstIndex(of: "("),
            trimmed.hasSuffix(")")
        else { return nil }
        let parts = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3 || parts.count == 4 else { return nil }
        let channels = parts.prefix(3).compactMap(Double.init)
        guard channels.count == 3, channels.allSatisfy({ (0...255).contains($0) }) else {
            return nil
        }
        let alpha = parts.count == 4 ? Double(parts[3]) : 1
        guard let alpha, (0...1).contains(alpha) else { return nil }
        return UIColor(
            red: channels[0] / 255, green: channels[1] / 255, blue: channels[2] / 255,
            alpha: alpha
        )
    }

    private static func hex(_ digits: String) -> UIColor? {
        let expanded =
            digits.count == 3 || digits.count == 4
            ? digits.map { "\($0)\($0)" }.joined() : digits
        guard expanded.count == 6 || expanded.count == 8,
            let value = UInt32(expanded, radix: 16)
        else { return nil }
        let bytes = expanded.count == 8 ? value : value << 8 | 0xFF
        return UIColor(
            red: CGFloat((bytes >> 24) & 0xFF) / 255,
            green: CGFloat((bytes >> 16) & 0xFF) / 255,
            blue: CGFloat((bytes >> 8) & 0xFF) / 255,
            alpha: CGFloat(bytes & 0xFF) / 255
        )
    }

    /// The JSON text as a Foundation value, or `nil` for `null`.
    private func json(of text: String) throws -> Any? {
        guard let data = text.data(using: .utf8) else { throw Unsupported.notAValue(text) }
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return value is NSNull ? nil : value
    }

    private func text(of json: String) throws -> String? {
        try self.json(of: json) as? String
    }

    /// What this adapter refuses, so core can report it rather than guess.
    enum Unsupported: Error {
        /// MapLibre here has no property for this spec key.
        case noProperty(String)
        /// MapLibre has the property but would not take the value.
        case refused(String, String)
        case noFilter(String)
        case notALayer(String)
        case notABackground(String)
        case notAValue(String)
    }

    /**
     The thirty-eight properties whose Objective-C name is not the spec key
     in camel case.

     Taken from the SDK's own headers, where each one documents the spec
     property it corresponds to. Everything absent from here follows
     ``camelCased(_:)``, and a key that is in neither comes back unapplied
     rather than being guessed at.
     */
    static let renamed: [String: String] = [
        "circle-pitch-scale": "circleScaleAlignment",
        "circle-translate": "circleTranslation",
        "circle-translate-anchor": "circleTranslationAnchor",
        "fill-antialias": "fillAntialiased",
        "fill-extrusion-translate": "fillExtrusionTranslation",
        "fill-extrusion-translate-anchor": "fillExtrusionTranslationAnchor",
        "fill-extrusion-vertical-gradient": "fillExtrusionHasVerticalGradient",
        "fill-translate": "fillTranslation",
        "fill-translate-anchor": "fillTranslationAnchor",
        "icon-allow-overlap": "iconAllowsOverlap",
        "icon-ignore-placement": "iconIgnoresPlacement",
        "icon-image": "iconImageName",
        "icon-keep-upright": "keepsIconUpright",
        "icon-rotate": "iconRotation",
        "icon-size": "iconScale",
        "icon-translate": "iconTranslation",
        "icon-translate-anchor": "iconTranslationAnchor",
        "line-dasharray": "lineDashPattern",
        "line-translate": "lineTranslation",
        "line-translate-anchor": "lineTranslationAnchor",
        "raster-brightness-max": "maximumRasterBrightness",
        "raster-brightness-min": "minimumRasterBrightness",
        "raster-hue-rotate": "rasterHueRotation",
        "raster-resampling": "rasterResamplingMode",
        "symbol-avoid-edges": "symbolAvoidsEdges",
        "text-allow-overlap": "textAllowsOverlap",
        "text-field": "text",
        "text-font": "textFontNames",
        "text-ignore-placement": "textIgnoresPlacement",
        "text-justify": "textJustification",
        "text-keep-upright": "keepsTextUpright",
        "text-max-angle": "maximumTextAngle",
        "text-max-width": "maximumTextWidth",
        "text-rotate": "textRotation",
        "text-size": "textFontSize",
        "text-translate": "textTranslation",
        "text-translate-anchor": "textTranslationAnchor",
        "text-writing-mode": "textWritingModes",
    ]
}
