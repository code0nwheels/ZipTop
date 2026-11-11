Pod::Spec.new do |s|
  s.name             = 'ziptop_avplayer'
  s.version          = '0.0.1'
  s.summary          = 'AVPlayer playback and AirPlay for ZipTop on macOS.'
  s.description      = 'Plays HLS through AVPlayer into a Flutter texture, with the AirPlay route picker.'
  s.homepage         = 'https://github.com/code0nwheels/ZipTop'
  s.license          = { :type => 'Proprietary', :text => 'Part of ZipTop.' }
  s.author           = 'ZipTop'
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.frameworks       = 'AVFoundation', 'AVKit', 'CoreMedia', 'CoreVideo', 'QuartzCore'
  # Keep in step with macos/Podfile.
  s.platform         = :osx, '13.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.0'
end
