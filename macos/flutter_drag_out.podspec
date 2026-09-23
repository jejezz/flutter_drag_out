#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_drag_out.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_drag_out'
  s.version          = '0.0.1'
  s.summary          = 'Drag files out of a Flutter desktop app via a native OS drag session.'
  s.description      = <<-DESC
Starts native NSDraggingSession drags carrying file URLs so files can be dragged
out of a Flutter macOS app into Finder and other applications.
                       DESC
  s.homepage         = 'https://github.com/jejezz/flutter_drag_out'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'jejezz' => 'jejezz@gmail.com' }

  s.source           = { :path => '.' }
  s.source_files = 'flutter_drag_out/Sources/flutter_drag_out/**/*'

  # If your plugin requires a privacy manifest, for example if it collects user
  # data, update the PrivacyInfo.xcprivacy file to describe your plugin's
  # privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'flutter_drag_out_privacy' => ['flutter_drag_out/Sources/flutter_drag_out/PrivacyInfo.xcprivacy']}

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
