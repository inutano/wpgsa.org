require "rake/testtask"

PROJ_ROOT = File.expand_path(__dir__)

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.libs << "."
  t.test_files = FileList["test/test_*.rb"]
  t.warning = false
end

Dir["#{PROJ_ROOT}/lib/tasks/**/*.rake"].each do |path|
  load path
end

task default: :test
