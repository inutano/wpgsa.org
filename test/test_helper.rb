require "bundler/setup"
require "minitest/autorun"

APP_ROOT = File.expand_path("..", __dir__)

$LOAD_PATH.unshift(APP_ROOT)
$LOAD_PATH.unshift(File.join(APP_ROOT, "lib"))
