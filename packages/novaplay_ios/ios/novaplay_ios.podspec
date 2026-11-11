Pod::Spec.new do |s|
  s.name             = 'novaplay_ios'
  s.version          = '0.1.0'
  s.summary          = 'Native iOS 15+ dual-kernel player (AVPlayer + MobileVLCKit), AirPlay, PiP, danmaku, haptics, and NodeMobile runtime for NovaPlay (星映).'
  s.description      = <<-DESC
    Implements Pigeon NativePlayerHostApi with iOS-native AVPlayer (VideoToolbox, PiP, AirPlay)
    and MobileVLCKit (FFmpeg multi-format + HW/SW decode), embedded Node.js loopback TCP bridge
    (uzv/node), Taptic Engine haptics (uzv/haptics), and lifecycle channel (uzv/app) for iOS 15.0+.
  DESC
  s.homepage         = 'https://novaplay.app'
  s.license          = { :type => 'MIT' }
  s.author           = { 'NovaPlay' => 'dev@novaplay.app' }
  s.source           = { :path => '.' }

  s.platforms        = { :ios => '15.0' }
  s.swift_version    = '5.0'

  s.source_files        = 'Classes/**/*.{h,m,mm,c,swift}'
  s.public_header_files = 'Classes/Node/UzvNodeRunner.h'

  s.dependency 'Flutter'
  # Required so CocoaPods cleanly encapsulates static binary frameworks (MobileVLCKit)
  s.static_framework = true
  if ENV['NOVAPLAY_WITH_VLC'] != '0'
    s.dependency 'MobileVLCKit', '~> 3.6.0'
  end

  s.frameworks = [
    'Foundation',
    'UIKit',
    'AVFoundation',
    'AVKit',
    'AudioToolbox',
    'CoreImage',
    'CoreMedia',
    'CoreGraphics',
    'CoreText',
    'CoreVideo',
    'MediaPlayer',
    'Photos',
    'QuartzCore',
    'Security',
    'SystemConfiguration',
    'UniformTypeIdentifiers',
    'VideoToolbox'
  ]
  s.libraries = 'c++', 'bz2', 'iconv', 'z'

  node_xcframework = File.join(__dir__, 'Frameworks', 'NodeMobile.xcframework')
  if Dir.exist?(node_xcframework)
    s.vendored_frameworks = 'Frameworks/NodeMobile.xcframework'
  end

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
end
