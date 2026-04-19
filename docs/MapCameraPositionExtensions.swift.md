# MapCameraPositionExtensions

Extensions that convert between the SDK's `MapCameraPosition` type and MapLibre camera types.

---

# MapCameraPosition extension

## `toMLNMapCamera()`

Converts a `MapCameraPosition` to an `MLNMapCamera` for use with MapLibre.

### Signature

```swift
public extension MapCameraPosition {
    func toMLNMapCamera() -> MLNMapCamera
}
```

### Returns

- Type: `MLNMapCamera`
- Description: An `MLNMapCamera` with center coordinate, pitch, and heading derived from the
  `MapCameraPosition`. Altitude is set to `0` (MapLibre uses zoom level, not altitude).

---

## `adjustedZoomForMapLibre()`

Returns the zoom level adjusted for MapLibre's zoom coordinate system.

### Signature

```swift
public extension MapCameraPosition {
    func adjustedZoomForMapLibre() -> Double
}
```

### Returns

- Type: `Double`
- Description: `zoom - 1.0`. MapLibre zoom levels are one unit lower than Google Maps zoom
  levels for the same visual scale. The constant `mapLibreCameraZoomAdjustValue = 1.0`.

---

# MLNMapView extension

## `toMapCameraPosition(visibleRegion:)`

Converts the current `MLNMapView` camera to a `MapCameraPosition`. Zoom is adjusted by adding
`1.0` to match the Google-style zoom coordinate system used by the SDK.

### Signature

```swift
public extension MLNMapView {
    func toMapCameraPosition(visibleRegion: VisibleRegion? = nil) -> MapCameraPosition
}
```

### Parameters

- `visibleRegion`
    - Type: `VisibleRegion?`
    - Default: `nil`
    - Description: The visible map region. When provided, the resulting `MapCameraPosition`
      includes accurate `visibleRegion` bounds.

### Returns

- Type: `MapCameraPosition`
- Description: A `MapCameraPosition` with zoom = `mlnZoomLevel + 1.0`.
