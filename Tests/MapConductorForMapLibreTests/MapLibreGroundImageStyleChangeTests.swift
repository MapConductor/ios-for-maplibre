import MapConductorCore
import MapLibre
import UIKit
import XCTest

@testable import MapConductorForMapLibre

/**
 A ground image survives the map design changing under it.

 Replacing the style throws away every source and layer added at runtime, so
 the controller has to put its images back into the new style. It used to keep
 the handle it made for the old style and, seeing an unchanged state, skip the
 image — which then vanished with the old style.

 Checked against a real `MLNMapView` loading real (local, empty) styles: the
 failure is in how the controller meets a new `MLNStyle`, and a stub style
 would agree with whatever the controller assumed.
 */
@MainActor
final class MapLibreGroundImageStyleChangeTests: XCTestCase {
    private final class StyleWaiter: NSObject, MLNMapViewDelegate {
        var expectation: XCTestExpectation?
        private(set) var style: MLNStyle?

        func mapView(_: MLNMapView, didFinishLoading style: MLNStyle) {
            self.style = style
            expectation?.fulfill()
        }
    }

    private var mapView: MLNMapView!
    private var waiter: StyleWaiter!
    private var styleURLs: [URL] = []

    override func setUp() async throws {
        styleURLs = try ["first", "second"].map { name in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("mc-groundimage-\(name)-\(UUID().uuidString).json")
            let json = """
            {"version": 8, "name": "\(name)", "sources": {},
             "layers": [{"id": "background", "type": "background"}]}
            """
            try json.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        waiter = StyleWaiter()
        mapView = MLNMapView(frame: CGRect(x: 0, y: 0, width: 256, height: 256), styleURL: nil)
        mapView.delegate = waiter
    }

    override func tearDown() async throws {
        mapView = nil
        waiter = nil
        for url in styleURLs { try? FileManager.default.removeItem(at: url) }
    }

    private func load(_ url: URL) async -> MLNStyle {
        let loaded = expectation(description: "style \(url.lastPathComponent) loaded")
        waiter.expectation = loaded
        mapView.styleURL = url
        await fulfillment(of: [loaded], timeout: 10)
        return waiter.style!
    }

    private func groundImage(id: String = "tokyo") -> GroundImage {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let bounds = GeoRectBounds(
            southWest: GeoPoint(latitude: 35.6, longitude: 139.6, altitude: 0),
            northEast: GeoPoint(latitude: 35.8, longitude: 139.9, altitude: 0)
        )
        return GroundImage(state: GroundImageState(bounds: bounds, image: image, id: id))
    }

    private func hasGroundImage(_ style: MLNStyle, id: String = "tokyo") -> Bool {
        style.source(withIdentifier: "mc-gimg-src-\(id)") != nil
            && style.layer(withIdentifier: "mc-gimg-lyr-\(id)") != nil
    }

    func testAnUnchangedGroundImageIsRecreatedInTheNewStyle() async {
        let controller = MapLibreGroundImageController(mapView: mapView)
        let first = await load(styleURLs[0])
        controller.onStyleLoaded(first)
        controller.syncGroundImages([groundImage()])
        XCTAssertTrue(hasGroundImage(first), "drawn in the first style")

        let second = await load(styleURLs[1])
        XCTAssertFalse(second === first, "the design change replaced the style")
        controller.onStyleLoaded(second)
        XCTAssertTrue(hasGroundImage(second), "drawn again in the new style, with nothing about it changed")

        // The host hands the same overlays over again after a reload; that has to
        // leave the image in place rather than treat it as already handled.
        controller.syncGroundImages([groundImage()])
        XCTAssertTrue(hasGroundImage(second))
        controller.unbind()
    }

    func testTheSameStyleLoadedAgainLeavesTheImageAlone() async {
        let controller = MapLibreGroundImageController(mapView: mapView)
        let style = await load(styleURLs[0])
        controller.onStyleLoaded(style)
        controller.syncGroundImages([groundImage()])
        let layer = style.layer(withIdentifier: "mc-gimg-lyr-tokyo")

        controller.onStyleLoaded(style)
        XCTAssertTrue(hasGroundImage(style))
        XCTAssertTrue(style.layer(withIdentifier: "mc-gimg-lyr-tokyo") === layer, "not recreated for a style it is already in")
        controller.unbind()
    }

    func testAGroundImageRemovedAfterTheChangeLeavesTheNewStyle() async {
        let controller = MapLibreGroundImageController(mapView: mapView)
        controller.onStyleLoaded(await load(styleURLs[0]))
        controller.syncGroundImages([groundImage()])

        let second = await load(styleURLs[1])
        controller.onStyleLoaded(second)
        controller.syncGroundImages([])
        XCTAssertFalse(hasGroundImage(second), "the recreated image is the one that gets removed")
        controller.unbind()
    }
}
