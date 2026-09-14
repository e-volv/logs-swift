Pod::Spec.new do |s|
  s.name = 'EvolveLogs'
  s.version = '0.1.1'
  s.summary = 'e-volv SDK for iOS and macOS: feature flags (e-volv Launch) and logs (e-volv Observer).'
  s.homepage = 'https://e-volv.io/docs/flags/sdk/swift'
  s.license = { type: 'MIT', file: 'LICENSE' }
  s.author = { 'e-volv' => 'support@e-volv.io' }
  s.source = { git: 'https://github.com/e-volv/logs-swift.git', tag: s.version.to_s }
  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '13.0'
  s.swift_version = '5.9'
  s.source_files = 'Sources/EvolveLogs/**/*.swift', 'Sources/EvolveLogsC/**/*.{c,h}'
  s.public_header_files = 'Sources/EvolveLogsC/include/*.h'
  s.libraries = 'z'
end
