Pod::Spec.new do |s|
  s.name             = 'novaplay_ios'
  s.version          = '0.1.0'
  s.summary          = 'Native iOS 15+ triple-kernel player (AVPlayer + MPV + MobileVLCKit), AirPlay, PiP, danmaku, haptics, and NodeMobile runtime for NovaPlay (星映).'
  s.description      = <<-DESC
    Implements Pigeon NativePlayerHostApi with iOS-native AVPlayer (VideoToolbox, PiP, AirPlay),
    MPV (libmpv + MoltenVK CAMetalLayer + VideoToolbox), and MobileVLCKit (FFmpeg multi-format + HW/SW decode),
    embedded Node.js loopback TCP bridge (uzv/node), Taptic Engine haptics (uzv/haptics), and lifecycle channel (uzv/app) for iOS 15.0+.
  DESC
  s.homepage         = 'https://novaplay.app'
  s.license          = { :type => 'MIT' }
  s.author           = { 'NovaPlay' => 'dev@novaplay.app' }
  s.source           = { :path => '.' }

  s.platforms        = { :ios => '15.0' }
  s.swift_version    = '5.0'

  s.source_files        = 'Classes/**/*.{h,m,mm,c,swift}'
  s.public_header_files = [
    'Classes/Node/UzvNodeRunner.h',
    'Classes/Player/UzvIosMpvBridge.h'
  ]
  s.resource_bundles    = {
    'novaplay_ios_resources' => ['Resources/player_icons.otf']
  }

  s.dependency 'Flutter'
  # Required so CocoaPods cleanly encapsulates static binary frameworks (MobileVLCKit) alongside dynamic XCFrameworks
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
    'CoreAudio',
    'CoreImage',
    'CoreMedia',
    'CoreGraphics',
    'CoreText',
    'CoreVideo',
    'IOSurface',
    'ImageIO',
    'MediaPlayer',
    'Metal',
    'Network',
    'Photos',
    'QuartzCore',
    'Security',
    'SystemConfiguration',
    'UniformTypeIdentifiers',
    'VideoToolbox'
  ]
  s.libraries = 'c++', 'bz2', 'iconv', 'resolv', 'xml2', 'z'

  vendored = []
  fw_root = File.join(__dir__, 'Frameworks')
  if Dir.exist?(fw_root)
    Dir.glob(File.join(fw_root, '*.xcframework')).sort.each do |xcfw_abs|
      name = File.basename(xcfw_abs)
      if name == 'NodeMobile.xcframework' || ENV['NOVAPLAY_WITH_MPV'] != '0'
        vendored << "Frameworks/#{name}"
      end
    end
  end
  unless vendored.empty?
    s.vendored_frameworks = vendored
  end

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
end
