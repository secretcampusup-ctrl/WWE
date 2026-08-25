Pod::Spec.new do |spec|
  spec.name = 'MobileVLCKit'
  spec.version = '3.4.1b13'
  spec.summary = "MobileVLCKit is an Objective-C wrapper for libvlc's external interface on iOS."
  spec.homepage = 'https://code.videolan.org/videolan/VLCKit'
  spec.documentation_url = 'https://wiki.videolan.org/VLCKit/'
  spec.license = { :type => 'LGPL v2.1', :file => 'COPYING.txt' }
  spec.author = { 'VideoLAN' => 'videolan@videolan.org' }

  spec.platform = :ios, '8.4'
  spec.source = {
    :http => 'https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.4.1b13-b3ea80ec-7c166c14.tar.xz',
    :sha256 => '2bc377cd6162c0c1673ec038c42a23e0fa7f0de1cac21b5e367a5bc48ac52a9d'
  }

  spec.ios.vendored_frameworks = 'MobileVLCKit.xcframework'
  spec.frameworks = %w[
    QuartzCore
    CoreText
    AVFoundation
    Security
    CFNetwork
    AudioToolbox
    OpenGLES
    CoreGraphics
    VideoToolbox
    CoreMedia
  ]
  spec.libraries = %w[c++ xml2 z bz2 iconv]
  spec.requires_arc = false
  spec.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++14',
    'CLANG_CXX_LIBRARY' => 'libc++'
  }
end
