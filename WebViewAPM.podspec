#
# Be sure to run `pod lib lint WebViewAPM.podspec' to ensure this is a
# valid spec before submitting.
#
# Any lines starting with a # are optional, but their use is encouraged
# To learn more about a Podspec see https://guides.cocoapods.org/syntax/podspec.html
#

Pod::Spec.new do |s|
  s.name             = 'WebViewAPM'
  s.version          = '0.1.0' # 初始版本号
  s.summary          = '用于监控 WKWebView 性能和错误的 APM SDK。'

# This description is used to generate tags and improve search results.
#   * Think: What does it do? Why did you write it? What is the focus?
#   * Try to keep it short, snappy and to the point.
#   * Write the description between the DESC delimiters below.
#   * Finally, don't worry about the indent, CocoaPods strips it!

  s.description      = <<-DESC
WebViewAPM 提供了一套工具，用于监控 iOS 应用中 WKWebView 的页面加载时间、JavaScript 错误、API 调用性能和资源加载情况。
                       DESC

  s.homepage         = 'https://github.com/iOSAPMTools/WebViewMetrics' # 替换为你的项目主页 URL
  # s.screenshots     = 'www.example.com/screenshots_1', 'www.example.com/screenshots_2'
  s.license          = { :type => 'MIT', :file => 'LICENSE' } # 确保项目中有 LICENSE 文件
  s.author           = { 'YOUR_NAME' => 'YOUR_EMAIL' } # 替换为你的名字和邮箱
  s.source           = { :git => 'https://github.com/iOSAPMTools/WebViewMetrics.git', :tag => s.version.to_s } # 替换为你的 Git 仓库 URL
  # s.social_media_url = 'https://twitter.com/<TWITTER_USERNAME>'

  s.ios.deployment_target = '13.0' # 与 Package.swift 保持一致
  s.swift_version = '5.5' # 指定所需的 Swift 版本

  # 定义源码文件路径
  s.source_files = 'WebViewAPM/Core/**/*.swift'

  # 定义资源文件路径
  s.resources = 'WebViewAPM/Resources/JavaScriptAgent.js'

  # 定义依赖的系统框架
  s.frameworks = 'WebKit'

  # s.dependency 'AFNetworking', '~> 2.3' # 如果有外部 CocoaPods 依赖，在这里添加
end 