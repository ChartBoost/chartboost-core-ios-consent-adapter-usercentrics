Pod::Spec.new do |spec|
  spec.name        = 'ChartboostCoreAdapterUsercentrics'
  spec.version     = '0.2.8.0.0'
  spec.license     = { :type => 'MIT', :file => 'LICENSE.md' }
  spec.homepage    = 'https://github.com/ChartBoost/chartboost-core-ios-cmp-usercentrics'
  spec.authors     = { 'Chartboost' => 'https://www.chartboost.com/' }
  spec.summary     = 'Chartboost Core iOS SDK Usercentrics Adapter.'
  spec.description = 'Usercentrics CMP adapters for mediating through Chartboost Core.'

  # Source
  spec.module_name  = 'ChartboostCoreAdapterUsercentrics'
  spec.source       = { :git => 'https://github.com/ChartBoost/chartboost-core-ios-cmp-usercentrics.git', :tag => spec.version }
  spec.source_files = 'Source/**/*.{swift}'

  # Minimum supported versions
  spec.swift_version         = '5.3'
  spec.ios.deployment_target = '11.0'

  # System frameworks used
  spec.ios.frameworks = ['Foundation', 'UIKit']
  
  # This adapter is compatible with all Chartboost Core 0.X versions of the SDK.
  spec.dependency 'ChartboostCoreSDK', '~> 0.0'

  # CMP SDK and version that this adapter is certified to work with.
  spec.dependency 'UsercentricsUI', '~> 2.8.0'
end
