# MapLibreDesign

`MapLibreDesign` is a struct that represents a MapLibre map style. It conforms to
`MapLibreMapDesignTypeProtocol` and wraps a `styleJsonURL` string value.

## Signature

```swift
public struct MapLibreDesign: MapLibreMapDesignTypeProtocol, Hashable {
    public let id: String
    public let styleJsonURL: String

    public init(id: String, styleJsonURL: String)
}
```

## Static Presets

- `DemoTiles` — A lightweight demo tile style for development and testing.
- `OsmBright` — OpenStreetMap Bright style (English labels).
- `OsmBrightJa` — OpenStreetMap Bright style (Japanese labels).
- `OsmBrightEn` — OpenStreetMap Bright style (English labels, alternate variant).
- `MapTilerTonerJa` — MapTiler Toner style (Japanese labels).
- `MapTilerTonerEn` — MapTiler Toner style (English labels).
- `MapTilerBasicEn` — MapTiler Basic style (English labels).
- `MapTilerBasicJa` — MapTiler Basic style (Japanese labels).
- `OpenMapTiles` — OpenMapTiles default style.

## Methods

### `getValue()`

Returns the style JSON URL string.

```swift
public func getValue() -> String
```

## Example

```swift
mapState.mapDesignType = MapLibreDesign.OsmBright

let custom = MapLibreDesign(
    id: "custom",
    styleJsonURL: "https://example.com/style.json"
)
mapState.mapDesignType = custom
```

---

# MapLibreMapDesignType

A type alias for `any MapLibreMapDesignTypeProtocol`.

## Signature

```swift
public typealias MapLibreMapDesignType = any MapLibreMapDesignTypeProtocol
```

---

# MapLibreMapDesignTypeProtocol

A protocol extending `MapDesignTypeProtocol` with `Identifier == String`.
Conforming types represent a MapLibre map style via a style JSON URL.

## Signature

```swift
public protocol MapLibreMapDesignTypeProtocol: MapDesignTypeProtocol
    where Identifier == String {
    var styleJsonURL: String { get }
}
```
