require 'rake'
require 'rake/testtask'

PROJECT_ROOT = File.expand_path(ENV.fetch('PROJECT_ROOT', Dir.pwd))
EXT_TEST_ROOT = File.expand_path(__dir__)

unless File.file?(File.join(PROJECT_ROOT, 'Gemfile')) && File.file?(File.join(PROJECT_ROOT, 'Rakefile'))
  abort "PROJECT_ROOT must point to a Ruby project with a Gemfile and Rakefile: #{PROJECT_ROOT}"
end

load File.join(EXT_TEST_ROOT, 'tasks/kea_integration.rake')
