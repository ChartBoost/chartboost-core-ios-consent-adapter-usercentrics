Pod::Spec.new do |spec|
  spec.name        = 'ChartboostCoreConsentAdapterUsercentrics'
  spec.version     = '1.2.29.0.0'
  spec.license     = { :type => 'MIT', :file => 'LICENSE.md' }
  spec.homepage    = 'https://github.com/ChartBoost/chartboost-core-ios-consent-adapter-usercentrics'
  spec.authors     = { 'Chartboost' => 'https://www.chartboost.com/' }
  spec.summary     = 'Chartboost Core iOS SDK Usercentrics Adapter.'
  spec.description = 'Usercentrics CMP adapters for mediating through Chartboost Core.'

  # Source
  spec.module_name  = 'ChartboostCoreConsentAdapterUsercentrics'
  spec.source       = { :git => 'https://github.com/ChartBoost/chartboost-core-ios-consent-adapter-usercentrics.git', :tag => spec.version }
  spec.source_files = 'Source/**/*.{swift}'
  spec.resource_bundles = {}

  # Minimum supported versions
  spec.swift_version         = '5.3'
  spec.ios.deployment_target = '13.0'

  # System frameworks used
  spec.ios.frameworks = ['Foundation', 'UIKit']

  # Dependencies
  spec.dependency 'ChartboostCoreSDK', '~> 1.0'
  spec.dependency 'UsercentricsUI', '~> 2.29.0'

  spec.static_framework = true
end
