Pod::Spec.new do |s|
  s.name = "MapConductorForMapLibre"
  s.version = "1.4.0"
  s.summary = "MapConductor's MapLibre provider."
  s.license = { :type => "Apache-2.0", :file => "LICENSE" }
  s.author = "MapConductor"
  s.homepage = "https://github.com/MapConductor/ios-for-maplibre"
  s.source = { :git => "https://github.com/MapConductor/ios-for-maplibre.git", :tag => s.version.to_s }
  s.platform = :ios, "15.5"
  s.swift_version = "5.9"
  s.source_files = "Sources/MapConductorForMapLibre/**/*.swift"
  s.dependency "MapConductorCore", "~> 1.4"
  # See CMapLibreStyleTry.podspec for why the Objective-C shim is its own pod.
  s.dependency "CMapLibreStyleTry", "~> 1.4"
  s.dependency "MapLibre", "~> 7.0"
end
