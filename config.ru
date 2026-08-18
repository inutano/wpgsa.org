require "bundler/setup"
Bundler.require(:default)

require File.expand_path("app", __dir__)
run WpgsaApp
