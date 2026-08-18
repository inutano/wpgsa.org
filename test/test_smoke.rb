require_relative "test_helper"
require "lib/wpgsa"

class TestSmoke < Minitest::Test
  def test_wpgsa_module_is_defined
    assert defined?(WPGSA)
  end

  def test_job_class_is_loaded
    assert defined?(WPGSA::Job)
  end
end
