Pod::Spec.new do |s|
  s.name = "CMapLibreStyleTry"
  s.version = "1.3.1"
  s.summary = "Objective-C exceptions from MapLibre's style API, caught for Swift."
  s.license = { :type => "Apache-2.0", :file => "LICENSE" }
  s.author = "MapConductor"
  s.homepage = "https://github.com/MapConductor/ios-for-maplibre"
  s.source = { :git => "https://github.com/MapConductor/ios-for-maplibre.git", :tag => s.version.to_s }
  s.platform = :ios, "15.1"
  # Its own pod for the same reason CTilePng is: `import CMapLibreStyleTry`
  # needs it to be a module, and Objective-C compiled *into* a Swift pod has
  # no module of its own. Swift Package Manager gives it one because it is a
  # separate target there; CocoaPods only does if it is a separate pod. The
  # consumer also needs `:modular_headers => true`.
  s.source_files = "Sources/CMapLibreStyleTry/**/*.{m,h}"
  s.public_header_files = "Sources/CMapLibreStyleTry/include/*.h"
  s.frameworks = "Foundation"
end
