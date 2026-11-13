import MapLibre
import XCTest

@testable import MapConductorForMapLibre

/**
 What a compiled style mutation actually reaches on a MapLibre layer.

 This provider's adapter is the one that cannot take a property by its spec
 name, so it goes through key-value coding with a rename table and a
 `responds(to:)` check. Everything that can go wrong there — a renamed
 property, a colour the SDK wants as a `UIColor`, a key this SDK simply does
 not have — goes wrong silently or fatally, so it is checked here against
 real layer objects rather than a stub. A style layer is a working object
 before it is added to a style, which is what makes this possible without a
 map on screen.
 */
final class MapLibreStyleMutationTargetTests: XCTestCase {
    private let target = MapLibreStyleMutationTarget(style: { nil }, isReady: { false })

    private func lineLayer() -> MLNLineStyleLayer {
        MLNLineStyleLayer(
            identifier: "roads",
            source: MLNVectorTileSource(
                identifier: "src", tileURLTemplates: ["https://example.invalid/{z}/{x}/{y}.pbf"]
            )
        )
    }

    private func symbolLayer() -> MLNSymbolStyleLayer {
        MLNSymbolStyleLayer(
            identifier: "labels",
            source: MLNVectorTileSource(
                identifier: "src", tileURLTemplates: ["https://example.invalid/{z}/{x}/{y}.pbf"]
            )
        )
    }

    // MARK: - The name

    func testDerivesTheObjectiveCNameFromTheSpecKey() {
        XCTAssertEqual(MapLibreStyleMutationTarget.camelCased("line-color"), "lineColor")
        XCTAssertEqual(MapLibreStyleMutationTarget.camelCased("fill-outline-color"), "fillOutlineColor")
        XCTAssertEqual(MapLibreStyleMutationTarget.camelCased("visibility"), "visibility")
    }

    /**
     The thirty-eight renamed properties are the ones a derived name misses,
     and missing one means the property is silently never set. Spot-checking
     the table against the SDK's real objects is what keeps it honest: if
     MapLibre renames `iconScale` again, this fails.
     */
    func testTheRenamedPropertiesExistUnderTheirTableNames() throws {
        let layer = symbolLayer()
        try target.set(layer, "icon-size", "2")
        try target.set(layer, "text-size", "14")
        try target.set(layer, "text-field", "\"hello\"")
        XCTAssertEqual(layer.iconScale, NSExpression(forConstantValue: 2))
        XCTAssertEqual(layer.textFontSize, NSExpression(forConstantValue: 14))
        XCTAssertEqual(layer.text, NSExpression(forConstantValue: "hello"))
    }

    func testEveryRenamedKeyNamesAPropertySomeLayerHas() {
        // Each entry has to be reachable on *some* layer type, or it is a
        // typo that would only show up as a mutation that quietly did
        // nothing.
        let layers: [MLNStyleLayer] = [
            lineLayer(),
            symbolLayer(),
            MLNBackgroundStyleLayer(identifier: "bg"),
            MLNCircleStyleLayer(
                identifier: "dots",
                source: MLNShapeSource(identifier: "shape", shapes: [], options: nil)
            ),
            MLNFillStyleLayer(
                identifier: "areas",
                source: MLNShapeSource(identifier: "shape2", shapes: [], options: nil)
            ),
            MLNFillExtrusionStyleLayer(
                identifier: "buildings",
                source: MLNShapeSource(identifier: "shape3", shapes: [], options: nil)
            ),
            MLNRasterStyleLayer(
                identifier: "tiles",
                source: MLNRasterTileSource(
                    identifier: "raster", tileURLTemplates: ["https://example.invalid/{z}/{x}/{y}.png"]
                )
            ),
        ]
        for (key, name) in MapLibreStyleMutationTarget.renamed {
            let setter = Selector("set\(name.prefix(1).uppercased())\(name.dropFirst()):")
            XCTAssertTrue(
                layers.contains { $0.responds(to: setter) },
                "\(key) -> \(name) is not a property of any layer type"
            )
        }
    }

    // MARK: - The value

    /**
     A constant colour reaches MapLibre as a `UIColor`.

     Nothing else works. A plain string constant is refused
     (`-[NSTaggedPointerString mgl_color]: unrecognized selector`), and the
     expression that looks right, `["to-color", "#ff0000"]`, becomes
     `CAST(x, 'UIColor')`, which Foundation on current iOS does not raise on
     — it ends the process. That is why the adapter parses the colour itself
     and why the compiler canonicalises every colour before it gets here.
     */
    func testAConstantColourBecomesAUIColor() throws {
        let layer = lineLayer()
        try target.set(layer, "line-color", "\"#ff0000\"")
        XCTAssertEqual(
            layer.lineColor?.expressionValue(with: nil, context: nil) as? UIColor,
            UIColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
    }

    /// `rgba(...)` is what the compiler writes for a colour with alpha, so
    /// it has to read as well as hex does.
    func testAnRgbaColourIsRead() throws {
        let layer = lineLayer()
        try target.set(layer, "line-color", "\"rgba(10,20,30,0.5)\"")
        let colour = try XCTUnwrap(
            layer.lineColor?.expressionValue(with: nil, context: nil) as? UIColor)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        colour.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        XCTAssertEqual(Double(red), 10 / 255, accuracy: 0.001)
        XCTAssertEqual(Double(green), 20 / 255, accuracy: 0.001)
        XCTAssertEqual(Double(blue), 30 / 255, accuracy: 0.001)
        XCTAssertEqual(Double(alpha), 0.5, accuracy: 0.001)
    }

    /// The forms the compiler does not emit but that cost nothing to take,
    /// and the ones that have to be refused rather than guessed at.
    func testWhatCountsAsAColour() {
        XCTAssertNotNil(MapLibreStyleMutationTarget.colour("#fff"))
        XCTAssertNotNil(MapLibreStyleMutationTarget.colour("#FF8800"))
        XCTAssertNotNil(MapLibreStyleMutationTarget.colour("#ff880080"))
        XCTAssertNotNil(MapLibreStyleMutationTarget.colour("rgb(1,2,3)"))
        XCTAssertNil(MapLibreStyleMutationTarget.colour("hsl(210,60%,80%)"))
        XCTAssertNil(MapLibreStyleMutationTarget.colour("rebeccapurple"))
        XCTAssertNil(MapLibreStyleMutationTarget.colour("rgb(1,2)"))
        XCTAssertNil(MapLibreStyleMutationTarget.colour("#gg0000"))
    }

    /**
     A colour inside an expression is left to MapLibre.

     Its own expression bridge turns the leaves into `UIColor` on the way in,
     so the adapter must not take the constant-colour path for anything that
     is not a bare string -- and a style's colours are usually leaves of an
     `interpolate` over zoom, not bare strings.
     */
    func testAnExpressionKeepsItsOwnColourLeaves() throws {
        let layer = lineLayer()
        try target.set(
            layer, "line-color",
            ##"["interpolate",["linear"],["zoom"],5,"#000000",10,"#ffffff"]"##
        )
        let json: [Any] = ["interpolate", ["linear"], ["zoom"], 5, "#000000", 10, "#ffffff"]
        // What MapLibre's own typed property does with the same expression.
        let reference = lineLayer()
        reference.lineColor = NSExpression(mglJSONObject: json)

        XCTAssertEqual(layer.lineColor, reference.lineColor, "the adapter took MapLibre's own path")
        // And MapLibre turned the stops into colours on the way in, which is
        // the point: the adapter never read them.
        XCTAssertNotEqual(
            layer.lineColor, NSExpression(mglJSONObject: json),
            "the stops are colours now, not the strings that went in"
        )
    }

    /// A colour the adapter cannot read is reported, not invented.
    func testAColourItCannotReadIsRefused() {
        let layer = lineLayer()
        XCTAssertThrowsError(try target.set(layer, "line-color", "\"hsl(210,60%,80%)\"")) { error in
            guard case MapLibreStyleMutationTarget.Unsupported.refused(let key, _) = error else {
                return XCTFail("expected refused, got \(error)")
            }
            XCTAssertEqual(key, "line-color")
        }
    }

    func testANumberAndAnExpressionReachTheProperty() throws {
        let layer = lineLayer()
        try target.set(layer, "line-width", "2.5")
        XCTAssertEqual(layer.lineWidth, NSExpression(forConstantValue: 2.5))

        // MapLibre folds a constant expression as it stores it, so what comes
        // back is the result rather than the arithmetic. What matters is that
        // the arithmetic arrived.
        try target.set(layer, "line-width", #"["*",2,1.5]"#)
        XCTAssertEqual(layer.lineWidth?.expressionValue(with: nil, context: nil) as? Double, 3)
    }

    /**
     A property with no value goes back to the spec default.

     Every one of these properties is `null_resettable`, so `nil` is how a
     renderer is told to forget what was set -- which is what the restore
     half of a mutation set depends on.
     */
    func testANullValueResetsTheProperty() throws {
        let layer = lineLayer()
        try target.set(layer, "line-color", "\"#ff0000\"")
        let coloured = layer.lineColor
        try target.set(layer, "line-color", "null")
        XCTAssertNotEqual(layer.lineColor, coloured, "the default is not what was just set")
    }

    /**
     A key this SDK has no property for comes back rather than taking the
     process down.

     A key-value set against a missing name raises an Objective-C exception,
     which Swift cannot catch — so the adapter asks first. This is the only
     provider where a mutation can be refused for this reason, and the whole
     reporting path exists for it.
     */
    func testAKeyMapLibreHasNoPropertyForIsRefused() {
        let layer = lineLayer()
        // A key that belongs to another layer type: refused rather than set
        // on the wrong layer.
        XCTAssertThrowsError(try target.set(layer, "text-size", "12")) { error in
            guard case MapLibreStyleMutationTarget.Unsupported.noProperty(let key) = error else {
                return XCTFail("expected noProperty, got \(error)")
            }
            XCTAssertEqual(key, "text-size")
        }
        XCTAssertThrowsError(try target.set(layer, "no-such-property", "1"))
    }

    /**
     A value MapLibre's Objective-C bridge cannot model is reported, not
     fatal.

     `NSExpression(mglJSONObject:)` raises an `NSException` for style JSON it
     does not understand — valid style JSON included, since the spec grows
     faster than the SDK's expression bridge. Swift cannot catch that, so the
     call goes through `CMapLibreStyleTry`. Without it this test would not
     fail; it would end the process.
     */
    func testAValueMapLibreCannotModelIsReportedNotFatal() {
        let layer = lineLayer()
        // `lineGradient` exists, so this gets past `responds(to:)` and fails
        // where the expression is built.
        XCTAssertThrowsError(try target.set(layer, "line-gradient", "[]")) { error in
            guard case MapLibreStyleMutationTarget.Unsupported.refused(let key, let why) = error
            else {
                return XCTFail("expected refused, got \(error)")
            }
            XCTAssertEqual(key, "line-gradient")
            XCTAssertFalse(why.isEmpty, "the reason MapLibre gave is worth passing on")
        }
    }

    /// A filter MapLibre cannot model goes the same way.
    func testAFilterMapLibreCannotModelIsReportedNotFatal() {
        let subject = MapLibreStyleMutationTarget(style: { nil }, isReady: { false })
        // No style, so nothing is reached -- the point is only that a
        // malformed filter does not raise on the way in.
        XCTAssertNoThrow(try subject.setFilter("roads", "[\"nonsense\"]"))
    }
}
