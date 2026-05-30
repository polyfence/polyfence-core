Pod::Spec.new do |s|
  s.name             = 'PolyfenceCore'
  s.version          = '1.0.9'
  s.summary          = 'Mobile surface of the Polyfence geofence layer — on-device polygon and circle geofencing for iOS.'
  s.description      = <<-DESC
    Native iOS engine for the Polyfence platform — the same zones you define
    once run on mobile, IoT, and server. On-device polygon (ray-casting) and
    circle (haversine) geofencing with SmartGPS, activity recognition, and
    aggregate-only telemetry. No coordinates, no identifiers, no PII about
    your end users. No cloud required from this library.
  DESC
  s.homepage         = 'https://github.com/polyfence/polyfence-core'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Polyfence' => 'hello@polyfence.io' }
  s.source           = { :git => 'https://github.com/polyfence/polyfence-core.git', :tag => "v#{s.version}" }

  s.ios.deployment_target = '14.0'
  s.swift_version = '5.0'

  s.source_files = 'ios/Classes/**/*.swift'

  s.frameworks = 'CoreLocation', 'CoreMotion', 'UserNotifications', 'BackgroundTasks', 'UIKit'

  s.pod_target_xcconfig = {
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
end
