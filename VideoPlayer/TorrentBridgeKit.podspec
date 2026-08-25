Pod::Spec.new do |s|
  s.name             = 'TorrentBridgeKit'
  s.version          = '2.0.1'
  s.summary          = 'libtorrent 2 bridge with a local HTTP range streaming server.'
  s.homepage         = 'https://github.com/ayman708-UX/libtorrent_flutter'
  s.license          = { :type => 'GPL-3.0', :file => 'LICENSE' }
  s.author           = { 'ayman708-UX' => 'ayman@example.com' }
  s.source           = {
    :git => 'https://github.com/ayman708-UX/libtorrent_flutter.git',
    :commit => '9a666923fcac04583e9a0abdacaeef9dc6ab6423'
  }

  s.platform = :ios, '16.0'
  s.static_framework = true
  s.vendored_frameworks = 'ios/libtorrent_flutter.xcframework'
  s.frameworks = 'SystemConfiguration', 'Security'
  s.libraries = 'c++', 'z'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'OTHER_LDFLAGS[sdk=iphoneos*]' => '-force_load "$(PODS_TARGET_SRCROOT)/ios/libtorrent_flutter.xcframework/ios-arm64/liblibtorrent_flutter.a"',
    'OTHER_LDFLAGS[sdk=iphonesimulator*]' => '-force_load "$(PODS_TARGET_SRCROOT)/ios/libtorrent_flutter.xcframework/ios-arm64_x86_64-simulator/liblibtorrent_flutter.a"'
  }
end
