Pod::Spec.new do |s|
  s.name = "MapConductorForMapLibre"
  s.version = "1.3.1"
  s.summary = "MapConductor's MapLibre provider."
  s.license = { :type => "Apache-2.0", :file => "LICENSE" }
  s.author = "MapConductor"
  s.homepage = "https://github.com/MapConductor/ios-for-maplibre"
  s.source = { :git => "https://github.com/MapConductor/ios-for-maplibre.git", :tag => s.version.to_s }
  s.platform = :ios, "15.1"
  s.swift_version = "5.9"
  s.source_files = "Sources/MapConductorForMapLibre/**/*.swift"
  s.dependency "MapConductorCore"
  s.dependency "MapLibre", "~> 6.20"
end
