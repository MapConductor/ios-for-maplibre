# MapLibreTypeAlias

Type aliases that map MapLibre SDK concrete types to the generic names used by the SDK's overlay
system.

## Aliases

- `MapLibreActualMarker`
    - Type: `MLNPointFeature`
    - Description: The MapLibre feature type used internally by the marker controller and
      renderer.
- `MapLibreActualPolyline`
    - Type: `MLNPolyline`
    - Description: The MapLibre shape type used for polyline rendering.
- `MapLibreActualCircle`
    - Type: `MLNPolygon`
    - Description: The MapLibre shape type used for circle rendering. Circles are approximated
      as polygons.
- `MapLibreActualPolygon`
    - Type: `MLNPolygon`
    - Description: The MapLibre shape type used for polygon rendering.

## Signature

```swift
public typealias MapLibreActualMarker   = MLNPointFeature
public typealias MapLibreActualPolyline = MLNPolyline
public typealias MapLibreActualCircle   = MLNPolygon
public typealias MapLibreActualPolygon  = MLNPolygon
```
