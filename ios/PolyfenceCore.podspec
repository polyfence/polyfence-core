Pod::Spec.new do |s|
  s.name             = 'PolyfenceCore'
  s.version          = '1.0.0'
  s.summary          = 'Privacy-first polygon and circle geofencing engine for iOS'
  s.description      = <<-DESC
    Standalone native geofencing SDK. On-device polygon (ray-casting) and circle
    (haversine) geofencing with SmartGPS, activity recognition, and built-in
    telemetry aggregation. No cloud required.
  DESC
  s.homepage         = 'https://github.com/polyfence/polyfence-core'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Polyfence' => 'hello@polyfence.io' }
  s.source           = { :git => 'https://github.com/polyfence/polyfence-core.git', :tag => "v#{s.version}" }

  s.ios.deployment_target = '14.0'
  s.swift_version = '5.0'

  s.source_files = 'Classes/**/*.swift'

  s.frameworks = 'CoreLocation', 'CoreMotion', 'UserNotifications', 'BackgroundTasks', 'UIKit'

  s.pod_target_xcconfig = {
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
end
